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

IB_DEVICES=${IB_DEVICES:-ionic_0,ionic_1,ionic_2,ionic_3,ionic_4,ionic_5,ionic_6,ionic_7}

export MC_GID_INDEX=${MC_GID_INDEX:-1}

if [[ -z "${MC_TCP_BIND_ADDRESS:-}" ]]; then
    MC_TCP_BIND_ADDRESS=$(ip -4 -o addr show 2>/dev/null \
        | awk '/inet 10\.2\./{split($4,a,"/"); print a[1]; exit}')
fi
if [[ -n "${MC_TCP_BIND_ADDRESS:-}" ]]; then
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
