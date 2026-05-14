#!/bin/bash
# =============================================================================
# Proxy / router for the 2-node prefill-decode disaggregation.
#
# Run on the prefill node (or any reachable host) inside the dev container,
# AFTER the prefill server and the decode server are both up.
#
# The router speaks OpenAI-compatible HTTP on 0.0.0.0:8000, dispatches the
# prefill phase to <prefill-host>:30000 (bootstrap 8998) and the decode phase
# to <decode-host>:30001. Override the host names via env if needed.
# =============================================================================
set -ex

PROXY_HOST=${PROXY_HOST:-0.0.0.0}
PROXY_PORT=${PROXY_PORT:-8000}

PREFILL_URL=${PREFILL_URL:-http://prefill-host:30000}
PREFILL_BOOTSTRAP_PORT=${PREFILL_BOOTSTRAP_PORT:-8998}
DECODE_URL=${DECODE_URL:-http://decode-host:30001}

python -m sglang_router.launch_router \
    --pd-disaggregation \
    --prefill "$PREFILL_URL" "$PREFILL_BOOTSTRAP_PORT" \
    --decode  "$DECODE_URL" \
    --host "$PROXY_HOST" \
    --port "$PROXY_PORT"
