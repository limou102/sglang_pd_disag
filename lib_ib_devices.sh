# =============================================================================
# lib_ib_devices.sh — shared helpers for picking RDMA NICs in a cross-node
# aligned order.
#
# This file is meant to be sourced (not executed). After sourcing, the public
# function `aligned_ib_devices` returns a comma-separated NIC list whose
# *position* is the same on every node of the cluster, even if the kernel
# enumerates the local ionic_N / mlx5_N indices in a different order on each
# host.
#
# Why position alignment matters
# ------------------------------
# Mooncake's RDMA transport (see mooncake-transfer-engine/src/transport/
# rdma_transport/worker_pool.cpp) pairs the two sides of a transfer by
# *device_id index*: when the sender picks its local context_list_[i], it
# directly indexes peer_segment_desc->devices[i] for the remote NIC. The two
# sides MUST therefore expose lists in which position i refers to NICs that
# can talk to each other (same RoCE subnet / same rail).
#
# Aligning by GID subnet
# ----------------------
# Every NIC on a given rail shares the same /64 GID subnet prefix. Sorting
# each node's local NIC list by that prefix is a stable per-node operation
# that produces the same global ordering on every node, with no inter-node
# coordination needed.
#
# Public API
# ----------
#   aligned_ib_devices
#       Print one line: "<nic>,<nic>,..." sorted by GID subnet.
#       Returns non-zero if no usable NIC found.
#
# Tunables (env)
# --------------
#   MC_GID_INDEX   GID index used as the sort key (default 1).
#                  Must match what the inference server / pingpong actually
#                  uses, so the sort key reflects the real path.
#   NICS           Comma-separated whitelist. If set, restrict the candidate
#                  pool to these NIC names (but still sort by subnet).
#   SKIP_NICS      Comma-separated blacklist. NICs in this list are removed
#                  from the result (after whitelist / auto-detect).
# =============================================================================

# Internal: scan /sys/class/infiniband, keep ACTIVE ports, group by kernel
# driver, return the largest group as a space-separated NIC list. This is the
# heuristic that picks the dedicated data-plane fabric on every cluster we've
# seen (ionic / mlx5 / bnxt_re ...), automatically dropping management NICs.
_ib_data_plane_group() {
    declare -A by_driver=()
    local d n s drv
    for d in /sys/class/infiniband/*; do
        [[ -d "$d" ]] || continue
        n=$(basename "$d")
        s=$(cat "$d/ports/1/state" 2>/dev/null || echo "")
        [[ "$s" == *"ACTIVE"* ]] || continue
        drv=$(readlink -f "$d/device/driver" 2>/dev/null)
        drv=$(basename "${drv:-unknown}")
        by_driver[$drv]+="$n "
    done
    local best="" best_count=0 count
    for drv in "${!by_driver[@]}"; do
        # shellcheck disable=SC2086
        count=$(echo ${by_driver[$drv]} | wc -w)
        if (( count > best_count )); then
            best_count=$count
            best=$drv
        fi
    done
    [[ -z "$best" ]] && return 1
    # shellcheck disable=SC2086
    echo ${by_driver[$best]}
}

# Internal: read the GID subnet (first 64 bits) at the configured index for a
# given NIC. Returns empty if no usable GID at that index.
_ib_subnet_of() {
    local nic=$1
    local gid_idx="${MC_GID_INDEX:-1}"
    local gid subnet
    gid=$(cat "/sys/class/infiniband/$nic/ports/1/gids/$gid_idx" 2>/dev/null)
    [[ -z "$gid" || "$gid" == "0000:0000:0000:0000:0000:0000:0000:0000" ]] && return 1
    subnet="${gid%:????:????:????:????}"
    echo "$subnet"
}

aligned_ib_devices() {
    local want="${NICS:-}"
    local skip="${SKIP_NICS:-}"
    local group

    if [[ -n "$want" ]]; then
        group="${want//,/ }"
    else
        group=$(_ib_data_plane_group) || return 1
    fi

    local n subnet
    local -a rows=()
    for n in $group; do
        [[ -n "$skip" && ",$skip," == *",$n,"* ]] && continue
        subnet=$(_ib_subnet_of "$n") || continue
        rows+=("$subnet $n")
    done
    (( ${#rows[@]} > 0 )) || return 1
    printf '%s\n' "${rows[@]}" | sort | awk '{print $2}' | paste -sd,
}
