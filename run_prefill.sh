#!/bin/bash
# =============================================================================
# Prefill server (run on the prefill node inside the dev container).
#
# Two-node PD-disaggregation layout:
#   prefill-node : prefill server  (this script)  + proxy/router
#   decode-node  : decode  server
#
# KV cache is shipped from prefill -> decode via mooncake-over-RDMA on the
# RoCE NICs. Make sure the container has a working RDMA provider first
# (see start_container.sh).
# =============================================================================
set -ex

cd "$(dirname "$0")"

MODEL_PATH=${MODEL_PATH:-/path/to/model}
SERVED_MODEL_NAME=${SERVED_MODEL_NAME:-MiniMax-M2.7}
TP_SIZE=${TP_SIZE:-2}

HOST=${PREFILL_HOST:-0.0.0.0}
PORT=${PREFILL_PORT:-30000}
BOOTSTRAP_PORT=${PREFILL_BOOTSTRAP_PORT:-8998}

# Auto-detect the RDMA NICs to feed mooncake if IB_DEVICES is not set.
#
# Heuristic: among /sys/class/infiniband/*, keep ports in ACTIVE state, group
# by kernel driver (ionic / mlx5_core / bnxt_re / ...), pick the largest
# group. This reliably selects the dedicated data-plane fabric on every
# cluster we've seen so far:
#   - old cluster (8x ionic, named ionic_0..ionic_7)
#   - current cluster (8x ionic 'rocepXs0' + 2x bnxt_re mgmt NICs -> ionic wins)
#   - Mellanox clusters (8x mlx5)
# If the heuristic guesses wrong, just `export IB_DEVICES=nic_a,nic_b,...`.
auto_detect_ib_devices() {
    declare -A by_driver=()
    local d name state drv
    for d in /sys/class/infiniband/*; do
        [[ -d "$d" ]] || continue
        name=$(basename "$d")
        state=$(cat "$d/ports/1/state" 2>/dev/null || echo "")
        [[ "$state" == *"ACTIVE"* ]] || continue
        drv=$(readlink -f "$d/device/driver" 2>/dev/null)
        drv=$(basename "${drv:-unknown}")
        by_driver[$drv]+="$name "
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
    echo ${by_driver[$best]} | tr ' ' '\n' | sort -V | paste -sd,
}

if [[ -z "${IB_DEVICES:-}" ]]; then
    IB_DEVICES=$(auto_detect_ib_devices || true)
fi
if [[ -z "$IB_DEVICES" ]]; then
    echo "[run_prefill] ERROR: no ACTIVE RDMA NICs found and IB_DEVICES is empty" >&2
    exit 1
fi
echo "[run_prefill] IB_DEVICES=$IB_DEVICES"

export MC_GID_INDEX=${MC_GID_INDEX:-1}

# Pick the data-plane IP from the 10.2.x.x net. sglang's get_local_ip_auto()
# would otherwise probe via UDP-connect to 8.8.8.8 and return the default-route
# source IP, which on these hosts is the *public* NIC (107.x / 144.x). Mooncake
# then registers the public IP as its handshake endpoint and KV transfers
# between nodes fail. Forcing SGLANG_HOST_IP / MC_TCP_BIND_ADDRESS to the
# data-plane IP keeps the control plane on the right NIC.
if [[ -z "${SGLANG_HOST_IP:-}" ]]; then
    SGLANG_HOST_IP=$(ip -4 -o addr show 2>/dev/null \
        | awk '/inet 10\.2\./{split($4,a,"/"); print a[1]; exit}')
fi
if [[ -n "${SGLANG_HOST_IP:-}" ]]; then
    export SGLANG_HOST_IP
    export HOST_IP="$SGLANG_HOST_IP"
    : "${MC_TCP_BIND_ADDRESS:=$SGLANG_HOST_IP}"
    export MC_TCP_BIND_ADDRESS
fi

python -m sglang.launch_server \
    --model-path "$MODEL_PATH" \
    --served-model-name "$SERVED_MODEL_NAME" \
    --trust-remote-code \
    --tp-size "$TP_SIZE" \
    --ep-size 1 \
    --dtype bfloat16 \
    --kv-cache-dtype fp8_e4m3 \
    --mem-fraction-static 0.90 \
    --attention-backend aiter \
    --enable-aiter-allreduce-fusion \
    --enable-hierarchical-cache \
    --chunked-prefill-size 16384 \
    --max-prefill-tokens 16384 \
    --page-size 1 \
    --hicache-ratio 1.5 \
    --max-running-requests 64 \
    --stream-interval 10 \
    --host "$HOST" \
    --port "$PORT" \
    --enable-metrics \
    --enable-cache-report \
    --log-requests \
    --log-requests-level 0 \
    --model-loader-extra-config '{"enable_multithread_load": true, "num_threads": 8}' \
    --tool-call-parser minimax-m2 \
    --reasoning-parser minimax-append-think \
    --disaggregation-mode prefill \
    --disaggregation-transfer-backend mooncake \
    --disaggregation-ib-device "$IB_DEVICES" \
    --disaggregation-bootstrap-port "$BOOTSTRAP_PORT" \
    --context-length 131072 \
