#!/bin/bash
# =============================================================================
# Universal container launcher for RDMA-enabled inference dev environments.
#
# What it does
# ------------
# 1. Scans /sys/class/infiniband/* on the HOST to figure out which RDMA NIC
#    vendor kernel drivers are loaded (bnxt_re, ionic, mlx5_core, ...).
# 2. Locates each vendor's userspace provider .so on the host.
# 3. Builds `docker run` with bind-mounts (-v) that overlay the host's
#    provider into every path libibverbs may search inside the container.
# 4. After the container starts, registers each provider with libibverbs
#    by writing /etc/libibverbs.d/<vendor>.driver and creating any required
#    SONAME symlinks.
# 5. Optionally runs check_rdma.sh as a sanity probe.
#
# Why this is portable across machines
# ------------------------------------
# The Broadcom bnxt_re case (sglang on ROCm) and the AMD Pensando ionic case
# (vllm on ROCm) both reduce to the same shape: "bind-mount the host's
# matching <vendor> .so into the right spots in the container, then declare it
# as a libibverbs driver". The script auto-detects which vendor is needed on
# the current host so the same script works on different hardware fleets.
#
# Usage
# -----
#     bash start_container.sh                 # uses defaults below
#
#     IMAGE=lmsysorg/sglang-rocm:v0.5.11-rocm720-mi35x-20260514 \
#     CONTAINER=sglang-rdma \
#     EXTRA_MOUNTS="-v /apps:/apps" \
#         bash start_container.sh
#
# Re-runnable: forcibly removes any prior container with the same name.
# =============================================================================
set -euo pipefail

# ---- user-configurable -----------------------------------------------------
IMAGE=${IMAGE:-lmsysorg/sglang-rocm:v0.5.12.post1-rocm720-mi35x-20260526}
CONTAINER=${CONTAINER:-sglang-rdma}
HOST_HOME=${HOST_HOME:-$HOME}

# Container runtime: docker or podman. Auto-detect if not set:
# prefer docker if the daemon is reachable, otherwise fall back to podman.
if [[ -z "${CONTAINER_CMD:-}" ]]; then
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        CONTAINER_CMD=docker
    elif command -v podman >/dev/null 2>&1; then
        CONTAINER_CMD=podman
    elif command -v docker >/dev/null 2>&1; then
        CONTAINER_CMD=docker
    else
        echo "[start_container] ERROR: neither docker nor podman is available" >&2
        exit 2
    fi
fi
echo "[start_container] container runtime : $CONTAINER_CMD"

# Extra bind-mounts / env flags. Pass as ONE shell-quoted string of docker args.
# Example: EXTRA_MOUNTS="-v /mnt/data:/mnt/data -v /apps:/apps"
EXTRA_MOUNTS_STR=${EXTRA_MOUNTS:-""}
# shellcheck disable=SC2206
EXTRA_MOUNTS=( $EXTRA_MOUNTS_STR )

# ---- helpers ---------------------------------------------------------------

# Map kernel RDMA driver name to libibverbs provider name.
provider_of() {
    case "$1" in
        bnxt_re|bnxt_en)    echo bnxt_re ;;
        ionic)              echo ionic ;;
        mlx5_core|mlx5_ib)  echo mlx5 ;;
        mlx4_core|mlx4_ib)  echo mlx4 ;;
        qedr)               echo qedr ;;
        irdma)              echo irdma ;;
        efa)                echo efa ;;
        rxe)                echo rxe ;;
        cxgb4)              echo cxgb4 ;;
        hfi1)               echo hfi1verbs ;;
        *)                  echo "$1" ;;
    esac
}

# Find the matching host-side userspace provider .so for a given provider
# name. Returns the resolved (no-symlink) path on stdout, or non-zero exit
# if nothing was found.
find_host_lib() {
    local prov=$1 c
    for c in \
        /usr/local/lib/lib${prov}-rdmav34.so \
        /usr/local/lib/x86_64-linux-gnu/lib${prov}-rdmav34.so \
        /usr/lib/x86_64-linux-gnu/lib${prov}-rdmav34.so \
        /usr/lib/x86_64-linux-gnu/libibverbs/lib${prov}-rdmav34.so \
        /usr/lib/x86_64-linux-gnu/lib${prov}.so.1 \
        /usr/local/lib/lib${prov}.so.1
    do
        # On some hosts (notably this fleet) /usr/local/lib/libbnxt_re-rdmav34.so
        # exists as an empty directory placeholder; only accept regular files.
        [[ -f "$c" && ! -d "$c" ]] && { readlink -f "$c"; return 0; }
    done
    # Fallback: glob versioned files like libionic.so.1.0.54.0-149.g3304be71
    local d f
    for d in /usr/lib/x86_64-linux-gnu /usr/local/lib /usr/local/lib/x86_64-linux-gnu; do
        for f in "$d"/lib${prov}.so.*; do
            [[ -f "$f" && ! -d "$f" ]] || continue
            readlink -f "$f"
            return 0
        done
    done
    return 1
}

# ---- discover host RDMA vendor drivers -------------------------------------

declare -A PROVIDERS
for dev in /sys/class/infiniband/*; do
    [[ -d "$dev" ]] || continue
    drv_path=$(readlink -f "$dev/device/driver" 2>/dev/null || true)
    [[ -z "$drv_path" ]] && continue
    prov=$(provider_of "$(basename "$drv_path")")
    PROVIDERS["$prov"]=1
done

if (( ${#PROVIDERS[@]} == 0 )); then
    echo "[start_container] ERROR: no /sys/class/infiniband devices found on host" >&2
    exit 2
fi

echo "[start_container] host RDMA providers : ${!PROVIDERS[*]}"

# ---- stage host providers into a side-car directory ------------------------
#
# We cannot rely on bind-mounting individual .so files onto paths that may not
# exist inside the image: with podman+crun, a "file -> missing path" bind
# mount fails with "Not a directory". Instead we stage every needed provider
# .so into a dedicated host directory, bind-mount that whole directory under
# /opt/host-rdma-providers in the container, and let the in-container helper
# below copy/symlink each .so into the canonical libibverbs locations.
PROVIDER_STAGE_DIR=$(mktemp -d -t rdma-providers.XXXXXX)
trap 'rm -rf "$PROVIDER_STAGE_DIR"' EXIT

INSTALLED_PROVIDERS=()
for prov in "${!PROVIDERS[@]}"; do
    src=$(find_host_lib "$prov" || true)
    if [[ -z "$src" ]]; then
        echo "[start_container] WARN: no host userspace provider for '$prov'; skipping"
        continue
    fi
    INSTALLED_PROVIDERS+=("$prov")
    echo "[start_container] $prov : $src"
    cp -f "$src" "$PROVIDER_STAGE_DIR/lib${prov}.so.host"
done

BIND_MOUNTS=(-v "$PROVIDER_STAGE_DIR:/opt/host-rdma-providers:ro")

# ---- (re)launch container --------------------------------------------------

if $CONTAINER_CMD ps -a --format '{{.Names}}' | grep -qx "$CONTAINER"; then
    echo "[start_container] removing existing container '$CONTAINER'"
    $CONTAINER_CMD rm -f "$CONTAINER" >/dev/null
fi

echo "[start_container] launching '$CONTAINER' from '$IMAGE'"

$CONTAINER_CMD run \
    -d \
    --name="$CONTAINER" \
    --ipc=host \
    --ulimit memlock=-1:-1 \
    --network=host \
    --device=/dev/kfd \
    --device=/dev/dri \
    --cap-add=SYS_PTRACE \
    --cap-add=CAP_SYS_ADMIN \
    --security-opt seccomp=unconfined \
    --group-add video \
    --privileged \
    --device=/dev/infiniband \
    --entrypoint /bin/bash \
    -v "$HOST_HOME":"$HOST_HOME" \
    "${EXTRA_MOUNTS[@]}" \
    "${BIND_MOUNTS[@]}" \
    "$IMAGE" \
    -c 'sleep infinity' >/dev/null

# ---- in-container provider registration ------------------------------------

if (( ${#INSTALLED_PROVIDERS[@]} > 0 )); then
    $CONTAINER_CMD exec "$CONTAINER" bash -c '
        set -e
        STAGE=/opt/host-rdma-providers
        mkdir -p /usr/lib/x86_64-linux-gnu/libibverbs /etc/libibverbs.d
        for prov in '"${INSTALLED_PROVIDERS[*]}"'; do
            host_so="$STAGE/lib${prov}.so.host"
            [[ -e "$host_so" ]] || continue
            # Copy the host provider into the canonical SONAME path and create
            # all the aliases libibverbs / downstream tools may dlopen.
            install -m 0755 "$host_so" "/usr/lib/x86_64-linux-gnu/lib${prov}.so.1"
            ln -sf "lib${prov}.so.1" "/usr/lib/x86_64-linux-gnu/lib${prov}.so"
            ln -sf "../lib${prov}.so.1" \
                   "/usr/lib/x86_64-linux-gnu/libibverbs/lib${prov}-rdmav34.so"
            # Register the provider so libibverbs auto-loads it on device probe.
            echo "driver ${prov}" > "/etc/libibverbs.d/${prov}.driver"
        done
        ldconfig
        echo "[start_container] /etc/libibverbs.d:"
        ls -1 /etc/libibverbs.d/ | sed "s/^/    /"
    '
fi

echo "[start_container] done. Try: $CONTAINER_CMD exec -it $CONTAINER bash"
