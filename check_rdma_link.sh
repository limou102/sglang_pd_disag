#!/bin/bash
# =============================================================================
# 2-node RoCE/IB RDMA connectivity check.
#
#   For every ACTIVE local RDMA NIC with a routable RoCE v2 GID, runs a small
#   `ibv_rc_pingpong` exchange (default n=1000, 4 KiB) against the peer node.
#   This validates:
#     1. NIC port is ACTIVE in sysfs and has a usable GID.
#     2. Data-plane TCP/IP between the two nodes is reachable
#        (ibv_rc_pingpong's bring-up handshake uses TCP; mori also uses TCP
#        for ZMQ control-plane).
#     3. An RC QP can be created and a small message exchange succeeds.
#
# Usage:
#
#   On the SERVER side (run first):
#       bash check_rdma_link.sh server
#
#   On the CLIENT side (run after server is up):
#       PEER_IP=<server-data-plane-ip> bash check_rdma_link.sh client
#
# Tunables (env):
#   PEER_IP           (client mode) data-plane IP of the server
#   NICS              comma-separated subset of NIC names to test
#                     (default: all ACTIVE NICs with a routable GID, minus SKIP_NICS)
#   SKIP_NICS=xeth0   comma-separated NIC names to exclude from the default set.
#                     xeth0 is a Pensando/Broadcom storage-mgmt port that
#                     advertises an ibverbs device but lives on a different L2
#                     than the rdma* ports; it always fails RC ping-pong
#                     between nodes and is never used by mooncake.
#   PORT_BASE=18515   first TCP port (one per NIC, sequential)
#   ITERS=1000        ibv_rc_pingpong iterations per NIC
#   INSTALL_TOOLS=1   auto apt-get install ibverbs-utils if missing
#   SERVER_GRACE=600  (server mode) seconds to keep servers alive
# =============================================================================
set -uo pipefail

MODE=${1:-}

NICS=${NICS:-}
SKIP_NICS=${SKIP_NICS:-xeth0}
PORT_BASE=${PORT_BASE:-18515}
ITERS=${ITERS:-1000}
INSTALL_TOOLS=${INSTALL_TOOLS:-1}
SERVER_GRACE=${SERVER_GRACE:-600} #timeout
PEER_IP=${PEER_IP:-}

red()    { printf '\e[31m%s\e[0m' "$*"; }
green()  { printf '\e[32m%s\e[0m' "$*"; }
yellow() { printf '\e[33m%s\e[0m' "$*"; }
hr()     { printf -- '----------------------------------------------------------------\n'; }

# -----------------------------------------------------------------------------
# Inner-script blobs.
# -----------------------------------------------------------------------------

# Ensure ibverbs-utils + ping are available, optionally apt-installing them.
ensure_tools_cmd='
    need=()
    command -v ibv_rc_pingpong >/dev/null 2>&1 || need+=(ibverbs-utils)
    command -v ibv_devinfo     >/dev/null 2>&1 || need+=(ibverbs-utils)
    command -v ping            >/dev/null 2>&1 || need+=(iputils-ping)
    [ ${#need[@]} -eq 0 ] && exit 0
    if [[ "'"$INSTALL_TOOLS"'" != "1" ]]; then
        echo "[ERROR] missing tools: ${need[*]}; set INSTALL_TOOLS=1 or install manually" >&2
        exit 1
    fi
    DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${need[@]}" \
        >/dev/null 2>&1 || {
        echo "[ERROR] failed to apt-get install ${need[*]}" >&2
        exit 1
    }
'

# Print one line per RDMA NIC: name|state|link|net|gid_idx|gid
# Skips IPv6 link-local GIDs (fe80::/10) and zero GIDs.
# Prefers IPv4-mapped RoCE v2 GIDs first, falls back to any non-link-local.
inventory_cmd='
    for d in /sys/class/infiniband/*; do
        [ -d "$d" ] || continue
        name=$(basename "$d")
        state=$(awk -F: "{print \$NF}" "$d/ports/1/state" 2>/dev/null | xargs)
        ll=$(cat "$d/ports/1/link_layer" 2>/dev/null)
        net=$(ls "$d/device/net/" 2>/dev/null | head -1)
        gididx=""; gidval=""
        for pass in v4 any; do
            [[ -n "$gididx" ]] && break
            for i in $(seq 0 31); do
                t=$(cat "$d/ports/1/gid_attrs/types/$i" 2>/dev/null)
                g=$(cat "$d/ports/1/gids/$i" 2>/dev/null)
                [[ "$t" == *"RoCE v2"* ]] || continue
                [[ "$g" == "0000:0000:0000:0000:0000:0000:0000:0000" ]] && continue
                [[ "$g" == fe80:* ]] && continue
                if [[ "$pass" == "v4" ]]; then
                    [[ "$g" == 0000:0000:0000:0000:0000:ffff:* ]] || continue
                fi
                gididx=$i; gidval=$g; break
            done
        done
        printf "%s|%s|%s|%s|%s|%s\n" "$name" "$state" "$ll" "$net" "${gididx:-NA}" "${gidval:-NA}"
    done
'

print_inventory() {
    local label=$1; shift
    echo "[check_rdma_link] $label NIC inventory:"
    printf "  %-10s %-9s %-9s %-12s %-7s %s\n" \
        DEV STATE LINK NET GID_IDX GID
    while IFS='|' read -r name state ll net gididx gid; do
        printf "  %-10s %-9s %-9s %-12s %-7s %s\n" \
            "$name" "$state" "$ll" "$net" "$gididx" "$gid"
    done < <("$@")
}

# Read inventory output and emit "<nic> <gid_idx>" pairs for ACTIVE NICs that
# have a usable GID. Filtered by $NICS (whitelist) if non-empty, otherwise the
# full set minus $SKIP_NICS (blacklist).
filter_nics() {
    local want="$NICS"
    local skip="$SKIP_NICS"
    while IFS='|' read -r n s l net gi gv; do
        [[ "$s" == "ACTIVE" ]] || continue
        [[ "$gi" != "NA"     ]] || continue
        if [[ -n "$want" ]]; then
            [[ ",$want," == *",$n,"* ]] || continue
        elif [[ -n "$skip" ]]; then
            [[ ",$skip," == *",$n,"* ]] && continue
        fi
        echo "$n $gi"
    done | sort -V
}

# -----------------------------------------------------------------------------
# Mode: server
# -----------------------------------------------------------------------------
mode_server() {
    bash -c "$ensure_tools_cmd" || { red "ibverbs-utils missing"; echo; exit 1; }
    print_inventory "local (server)" bash -c "$inventory_cmd"

    mapfile -t pairs < <(bash -c "$inventory_cmd" | filter_nics)
    if [[ ${#pairs[@]} -eq 0 ]]; then
        red "no usable RoCE v2 NIC"; echo; exit 2
    fi

    pids=()
    ports=()
    nics=()
    i=0
    echo "[check_rdma_link] starting servers ..."
    for p in "${pairs[@]}"; do
        nic=${p%% *}; gid=${p##* }
        port=$((PORT_BASE + i))
        i=$((i+1))
        log=/tmp/rc_pp_${nic}_${port}.srv.log
        rm -f "$log"
        ibv_rc_pingpong -d "$nic" -g "$gid" -p "$port" -n "$ITERS" -i 1 \
            >"$log" 2>&1 &
        pids+=($!)
        ports+=("$port")
        nics+=("$nic")
        echo "  $nic gid=$gid port=$port pid=${pids[-1]} log=$log"
    done
    hr

    echo "[check_rdma_link] waiting for clients (each server exits after $ITERS exchanges; max ${SERVER_GRACE}s) ..."
    deadline=$(( $(date +%s) + SERVER_GRACE ))
    while (( ${#pids[@]} > 0 )); do
        alive=()
        for pid in "${pids[@]}"; do
            kill -0 "$pid" 2>/dev/null && alive+=("$pid")
        done
        pids=("${alive[@]}")
        (( ${#pids[@]} == 0 )) && break
        if (( $(date +%s) >= deadline )); then
            yellow "[WARN] $((${#pids[@]})) server(s) still up after ${SERVER_GRACE}s, killing"; echo
            for pid in "${pids[@]}"; do kill -9 "$pid" 2>/dev/null || true; done
            break
        fi
        sleep 0.5
    done

    overall=0
    echo "[check_rdma_link] server-side per-NIC summary:"
    printf "  %-10s %-6s %s\n" DEV PORT RESULT
    for idx in "${!nics[@]}"; do
        nic=${nics[$idx]}; port=${ports[$idx]}
        log=/tmp/rc_pp_${nic}_${port}.srv.log
        if grep -q "Mbit/sec" "$log" 2>/dev/null; then
            printf "  %-10s %-6s %s\n" "$nic" "$port" "$(green PASS)"
        else
            printf "  %-10s %-6s %s\n" "$nic" "$port" "$(red FAIL)"
            echo "    ----- $log -----"
            sed 's/^/    /' "$log"
            overall=1
        fi
    done
    exit "$overall"
}

# -----------------------------------------------------------------------------
# Mode: client
# -----------------------------------------------------------------------------
mode_client() {
    if [[ -z "$PEER_IP" ]]; then
        red "PEER_IP must be set in client mode"; echo; exit 1
    fi
    bash -c "$ensure_tools_cmd" || { red "ibverbs-utils missing"; echo; exit 1; }
    print_inventory "local (client)" bash -c "$inventory_cmd"

    mapfile -t pairs < <(bash -c "$inventory_cmd" | filter_nics)
    if [[ ${#pairs[@]} -eq 0 ]]; then
        red "no usable RoCE v2 NIC"; echo; exit 2
    fi

    echo "[check_rdma_link] data-plane reachability:"
    if command -v ping >/dev/null 2>&1; then
        rtt=$(ping -c 2 -W 2 -q "$PEER_IP" 2>/dev/null | awk -F/ '/rtt/{print $5}')
        [[ -n "$rtt" ]] \
            && echo "  ping  -> $PEER_IP avg_rtt=${rtt}ms $(green OK)" \
            || { echo "  ping  -> $PEER_IP $(red UNREACHABLE)"; exit 3; }
    else
        if timeout 2 bash -c "exec 3<>/dev/tcp/$PEER_IP/22" 2>/dev/null; then
            echo "  tcp:22 -> $PEER_IP $(green OK)  (ping not installed; used TCP probe)"
        else
            yellow "  tcp:22 -> $PEER_IP not reachable; continuing anyway"; echo
        fi
    fi
    hr

    echo "[check_rdma_link] per-NIC RC ping-pong  (n=$ITERS, peer=$PEER_IP)"
    printf "  %-10s %-6s %-7s %-30s %s\n" DEV PORT GID BANDWIDTH/LATENCY RESULT
    overall=0; i=0
    declare -a fails
    for p in "${pairs[@]}"; do
        nic=${p%% *}; gid=${p##* }
        port=$((PORT_BASE + i))
        i=$((i+1))

        out=$(ibv_rc_pingpong -d "$nic" -g "$gid" -p "$port" -n "$ITERS" -i 1 \
                "$PEER_IP" 2>&1); rc=$?
        line=$(printf '%s\n' "$out" | grep -E "Mbit/sec|usec/iter" | head -1 | xargs)
        [[ -z "$line" ]] && line=$(printf '%s\n' "$out" | tail -2 | head -1 | xargs)
        if (( rc == 0 )); then
            printf "  %-10s %-6s %-7s %-30s %s\n" "$nic" "$port" "$gid" "${line:0:30}" "$(green PASS)"
        else
            printf "  %-10s %-6s %-7s %-30s %s\n" "$nic" "$port" "$gid" "${line:0:30}" "$(red "FAIL rc=$rc")"
            fails+=("$nic"$'\n'"$out")
            overall=1
        fi
    done
    hr
    if (( overall == 0 )); then
        echo "[check_rdma_link] $(green ALL OK) - ${#pairs[@]} NIC pair(s) verified"
    else
        echo "[check_rdma_link] $(red FAILED)"
        for f in "${fails[@]}"; do echo "---"; echo "$f"; done
    fi
    exit "$overall"
}

# -----------------------------------------------------------------------------
# entrypoint
# -----------------------------------------------------------------------------
case "$MODE" in
    server) mode_server ;;
    client) mode_client ;;
    -h|--help|help|"")
        sed -n '2,30p' "$0"
        exit 0 ;;
    *)
        echo "unknown mode: $MODE (expected: server | client)" >&2
        exit 64 ;;
esac
