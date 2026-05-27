# =============================================================================
# lib_ib_devices.sh — shared helpers for picking RDMA NICs.
#
# This file is meant to be sourced (not executed). It exposes the public
# function `aligned_ib_devices`, used by run_prefill.sh / run_decode.sh /
# check_rdma_link.sh.
#
# Public API
# ----------
#   aligned_ib_devices
#       Print one line: "<nic>,<nic>,..." with the data-plane NICs.
#       Default ordering is the kernel's natural NIC-name order
#       (e.g. ionic_0, ionic_1, ..., ionic_7); export
#       `IB_DEVICES_SORT_BY_SUBNET=1` to instead order by RoCE GID subnet
#       (first 64 bits of the GID at MC_GID_INDEX) — useful when the
#       downstream consumer pairs NICs by list position across nodes.
#       Returns non-zero if no usable NIC found.
#
# Tunables (env)
# --------------
#   MC_GID_INDEX                GID index read when subnet sorting is on
#                               (default 1). Must match what the inference
#                               server / pingpong actually uses, so the sort
#                               key reflects the real RDMA path.
#   NICS                        Comma-separated whitelist. If set, restrict
#                               the candidate pool to these NIC names.
#   SKIP_NICS                   Comma-separated blacklist. NICs in this list
#                               are removed from the result (after whitelist
#                               / auto-detect).
#   IB_DEVICES_SORT_BY_SUBNET   If "1" / "true" / "yes", switch ordering from
#                               NIC name to GID subnet. Off by default.
#
# Why subnet sorting exists
# -------------------------
# A given cluster typically has N RoCE "rails", each rail = one RDMA switch
# = one /64 IPv6 GID subnet. On every node, one NIC sits on each rail.
# Kernels do NOT guarantee that the local <driver>_N indexing follows the
# same physical order across hosts: the same physical NIC at PCI 09:00.0
# may be `ionic_0` on one node and `ionic_3` on another. When a peer pairs
# the two sides by list position (e.g. "my Nth NIC talks to your Nth NIC"),
# sorting both sides by the rail's GID subnet — a globally stable key —
# makes "position i" mean "the NIC on the i-th rail" everywhere, with no
# inter-node coordination needed.
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
    local sort_by_subnet="${IB_DEVICES_SORT_BY_SUBNET:-0}"
    local group

    if [[ -n "$want" ]]; then
        group="${want//,/ }"
    else
        group=$(_ib_data_plane_group) || return 1
    fi

    # Apply the SKIP_NICS blacklist to the candidate set first; both ordering
    # modes consume the same filtered list.
    local n
    local -a candidates=()
    for n in $group; do
        [[ -n "$skip" && ",$skip," == *",$n,"* ]] && continue
        candidates+=("$n")
    done
    (( ${#candidates[@]} > 0 )) || return 1

    case "${sort_by_subnet,,}" in
        1|true|yes|on)
            # Subnet-sorted ordering: read each NIC's GID subnet (NICs whose
            # GID at MC_GID_INDEX isn't usable are dropped here).
            local subnet
            local -a rows=()
            for n in "${candidates[@]}"; do
                subnet=$(_ib_subnet_of "$n") || continue
                rows+=("$subnet $n")
            done
            (( ${#rows[@]} > 0 )) || return 1
            printf '%s\n' "${rows[@]}" | sort | awk '{print $2}' | paste -sd,
            ;;
        *)
            # Default: kernel's natural NIC-name order (sort -V keeps ionic_2
            # before ionic_10 etc.).
            printf '%s\n' "${candidates[@]}" | sort -V | paste -sd,
            ;;
    esac
}
