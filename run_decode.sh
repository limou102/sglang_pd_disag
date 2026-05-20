#!/bin/bash
# =============================================================================
# Decode server (run on the decode node inside the dev container).
#
# See run_prefill.sh for the overall topology. The decode server discovers the
# prefill side via the prefill's bootstrap port carried in the request
# metadata; nothing has to be pre-configured here.
# =============================================================================
set -ex

cd "$(dirname "$0")"

MODEL_PATH=${MODEL_PATH:-/path/to/model}
SERVED_MODEL_NAME=${SERVED_MODEL_NAME:-MiniMax-M2.7}
TP_SIZE=${TP_SIZE:-2}

HOST=${DECODE_HOST:-0.0.0.0}
PORT=${DECODE_PORT:-30001}

# See run_prefill.sh for the rationale of the heuristic below: pick the
# largest group of ACTIVE same-driver RDMA NICs as the data-plane fabric.
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
    echo "[run_decode] ERROR: no ACTIVE RDMA NICs found and IB_DEVICES is empty" >&2
    exit 1
fi
echo "[run_decode] IB_DEVICES=$IB_DEVICES"

export MC_GID_INDEX=${MC_GID_INDEX:-1}

# See run_prefill.sh for the rationale: lock sglang's local IP resolution to
# the 10.2.x.x data-plane subnet so mooncake's control plane / handshake
# endpoint isn't published as the public NIC IP.
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
    --page-size 1 \
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
    --disaggregation-mode decode \
    --disaggregation-transfer-backend mooncake \
    --disaggregation-ib-device "$IB_DEVICES" \
    --context-length 131072
