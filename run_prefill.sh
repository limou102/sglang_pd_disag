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
# See lib_ib_devices.sh for the full rationale; the short version is:
#   * pick the largest same-driver group of ACTIVE NICs as the data-plane;
#   * sort that group by RoCE GID subnet so list positions align across nodes
#     (required by mooncake's device_id-indexed pairing).
# Override either piece manually with `export IB_DEVICES=nic_a,nic_b,...`
# or restrict the candidate pool with `export NICS=...` / `export SKIP_NICS=...`.
# shellcheck source=lib_ib_devices.sh
source "$(dirname "$0")/lib_ib_devices.sh"

if [[ -z "${IB_DEVICES:-}" ]]; then
    IB_DEVICES=$(aligned_ib_devices || true)
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
