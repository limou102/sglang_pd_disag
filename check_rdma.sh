#!/bin/bash
# =============================================================================
# Preflight RDMA / mori-IO check for the MoRIIOConnector.
#
# Verifies that the `mori` python package can open an RDMA backend inside the
# current process. Three things have to be in place:
#
#   1) /sys/class/infiniband/<dev>/ports/1/state == "ACTIVE"
#   2) The libibverbs userspace provider (.so) for that NIC is reachable
#      under /usr/lib/x86_64-linux-gnu/libibverbs/ (or LD_LIBRARY_PATH).
#   3) /etc/libibverbs.d/<provider>.driver lists that provider so libibverbs
#      actually dlopen()s it.
#
# On AMD MI355X + AMD Pensando (ionic) hosts, the vllm/vllm-openai-rocm:v0.20.0
# container ships an inbox rdma-core 39.0-1 that knows nothing about ionic, so
# we install the host's libionic provider and register the driver. We do the
# same for any other vendor (.so available on the host, .driver missing in the
# container).
#
# Run inside the SAME container in which you intend to start the inference
# server:
#   bash check_rdma.sh
#
# Re-run this script after restarting the container to recreate the bind.
# =============================================================================
set -uo pipefail

VERBS_DIR=/usr/lib/x86_64-linux-gnu/libibverbs
DRIVER_DIR=/etc/libibverbs.d
HOST_VERBS_DIR=${HOST_VERBS_DIR:-/usr/lib/x86_64-linux-gnu/libibverbs}
HOST_LIB_DIR=${HOST_LIB_DIR:-/usr/lib/x86_64-linux-gnu}

echo "[check_rdma] kernel:      $(uname -r)"
echo "[check_rdma] ibverbs lib: $(dpkg -l libibverbs1 2>/dev/null | awk '/ii/{print $3}')"

# ---- list IB devices via sysfs (ibv_devices is not installed in the base image)
echo "[check_rdma] /sys/class/infiniband:"
if [[ -d /sys/class/infiniband ]]; then
    for d in /sys/class/infiniband/*; do
        [[ -d $d ]] || continue
        name=$(basename "$d")
        state=$(cat "$d/ports/1/state" 2>/dev/null || echo "?")
        ll=$(cat "$d/ports/1/link_layer" 2>/dev/null || echo "?")
        net=$(ls "$d/device/net/" 2>/dev/null | head -1)
        echo "                  $name  state=$state  link=$ll  net=$net"
    done
else
    echo "                  (none)"
fi

# ---- 1) ensure missing vendor providers are populated ----------------------
#
# For every <prov>.driver entry we may want, check whether the provider .so
# exists in the container; if not but it does on the host (bind-mounted at
# HOST_VERBS_DIR / HOST_LIB_DIR), copy it in.
#
# The most common case on this fleet is the AMD Pensando "ionic" provider:
#   container has libibverbs 39.0-1 from rdma-core (no ionic), but the host
#   ships /usr/lib/x86_64-linux-gnu/libionic.so.1.* and
#   /usr/lib/x86_64-linux-gnu/libibverbs/libionic-rdmav34.so. We install both.
ensure_ionic_provider() {
    if [[ -e "$VERBS_DIR/libionic-rdmav34.so" ]]; then
        return 0
    fi
    local host_so
    host_so=$(ls -1 "$HOST_LIB_DIR"/libionic.so.1.*.* 2>/dev/null | head -1 || true)
    if [[ -z "$host_so" ]]; then
        echo "[check_rdma] WARN: no host libionic.so.1.* found at $HOST_LIB_DIR;"
        echo "[check_rdma] WARN: cannot auto-install the ionic provider."
        return 1
    fi
    local base
    base=$(basename "$host_so")
    echo "[check_rdma] installing ionic ibverbs provider:"
    echo "             $host_so -> $HOST_LIB_DIR/$base"
    cp -f "$host_so" "$HOST_LIB_DIR/$base"
    ln -sf "$base"               "$HOST_LIB_DIR/libionic.so.1"
    ln -sf libionic.so.1         "$HOST_LIB_DIR/libionic.so"
    ln -sf "../$base"            "$VERBS_DIR/libionic-rdmav34.so"
    return 0
}

ensure_driver_listed() {
    # Append "driver <name>" to /etc/libibverbs.d/<name>.driver if missing.
    local prov=$1
    local f="$DRIVER_DIR/$prov.driver"
    if [[ -f "$f" ]] && grep -q "^driver $prov" "$f"; then
        return 0
    fi
    echo "[check_rdma] registering provider '$prov' in $f"
    mkdir -p "$DRIVER_DIR"
    echo "driver $prov" > "$f"
}

ensure_ionic_provider || true
# Always (re-)assert the .driver entry; cheap.
[[ -e "$VERBS_DIR/libionic-rdmav34.so" ]] && ensure_driver_listed ionic

# ---- 2) probe mori ----------------------------------------------------------
python3 - <<'PY'
import os, socket, sys
try:
    from mori.io import (
        BackendType, IOEngine, IOEngineConfig,
        RdmaBackendConfig, PollCqMode,
    )
except Exception as e:  # noqa: BLE001
    print(f"[check_rdma] FAIL: cannot import mori.io ({e!r})")
    sys.exit(2)

# Bind to loopback so the probe never depends on a routable IP being
# configured on a NIC. mori still scans every RDMA device on the host.
ip = "127.0.0.1"
try:
    eng = IOEngine("preflight:probe", IOEngineConfig(ip, 0))
    eng.create_backend(BackendType.RDMA, RdmaBackendConfig(1, -1, 1, PollCqMode.POLLING))
    desc = eng.get_engine_desc()
    print(f"[check_rdma] OK: mori RDMA backend opened on {ip} key={desc.key}")
    sys.exit(0)
except Exception as e:  # noqa: BLE001
    print(f"[check_rdma] FAIL: mori cannot open an RDMA backend ({e!r})")
    sys.exit(3)
PY
rc=$?
if [[ $rc -eq 0 ]]; then
    exit 0
fi

cat <<'HINT'

[check_rdma] mori-IO failed to open an RDMA backend.

Common causes:

1. The vendor userspace provider (.so) for your NIC is missing inside the
   container. We attempt to auto-install the AMD Pensando 'ionic' provider
   from the host (/usr/lib/x86_64-linux-gnu/libionic.so.1.*) but for other
   NICs you may need to do the same by hand, e.g. for Mellanox:
     cp /usr/lib/x86_64-linux-gnu/libmlx5-rdmav34.so \
        /usr/lib/x86_64-linux-gnu/libibverbs/

2. /etc/libibverbs.d/<provider>.driver is missing. Add it:
     echo "driver ionic" > /etc/libibverbs.d/ionic.driver

3. ABI mismatch between the host kernel module and the container's libibverbs
   provider (e.g. bnxt_re kABI 6 vs container kABI 1). Replace the container's
   libbnxt_re-rdmav34.so with the host's vendor build.

4. No NIC has its port in state ACTIVE - check the dump above.

HINT
exit $rc
