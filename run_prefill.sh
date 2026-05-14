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

# TP=2 across two GPUs on this node. Override via env if needed.
export HIP_VISIBLE_DEVICES=${HIP_VISIBLE_DEVICES:-0,1}

# Default to the Hugging Face model id; override MODEL_PATH=/local/path to use
# a locally cached copy.
MODEL_PATH=${MODEL_PATH:-MiniMaxAI/MiniMax-M2.7}
SERVED_MODEL_NAME=${SERVED_MODEL_NAME:-MiniMax-M2.7}
TP_SIZE=${TP_SIZE:-2}

HOST=${PREFILL_HOST:-0.0.0.0}
PORT=${PREFILL_PORT:-30000}
BOOTSTRAP_PORT=${PREFILL_BOOTSTRAP_PORT:-8998}

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
    --disaggregation-mode prefill \
    --disaggregation-transfer-backend mooncake \
    --disaggregation-ib-device "$IB_DEVICES" \
    --disaggregation-bootstrap-port "$BOOTSTRAP_PORT"
