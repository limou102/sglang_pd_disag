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

export HIP_VISIBLE_DEVICES=${HIP_VISIBLE_DEVICES:-4,5}

# Default to the Hugging Face model id; override MODEL_PATH=/local/path to use
# a locally cached copy.
MODEL_PATH=${MODEL_PATH:-MiniMaxAI/MiniMax-M2.7}
SERVED_MODEL_NAME=${SERVED_MODEL_NAME:-MiniMax-M2.7}
TP_SIZE=${TP_SIZE:-2}

HOST=${DECODE_HOST:-0.0.0.0}
PORT=${DECODE_PORT:-30001}

# Pin mooncake to the 8 RoCE NICs only; xeth0 is a storage/mgmt port whose
# subnet is not reachable across nodes and causes RDMA QP RTR timeouts.
IB_DEVICES=${IB_DEVICES:-rdma0,rdma1,rdma2,rdma3,rdma4,rdma5,rdma6,rdma7}

python -m sglang.launch_server \
    --model-path "$MODEL_PATH" \
    --served-model-name "$SERVED_MODEL_NAME" \
    --trust-remote-code \
    --tp-size "$TP_SIZE" \
    --mem-fraction-static 0.85 \
    --attention-backend aiter \
    --enable-mixed-chunk \
    --chunked-prefill-size 8192 \
    --max-prefill-tokens 16384 \
    --max-running-requests 64 \
    --host "$HOST" \
    --port "$PORT" \
    --disaggregation-mode decode \
    --disaggregation-transfer-backend mooncake \
    --disaggregation-ib-device "$IB_DEVICES"
