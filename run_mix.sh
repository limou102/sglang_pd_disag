set -ex

MODEL_PATH=${MODEL_PATH:-/mnt/vast/limou/models/MiniMaxAI/MiniMax-M2.7}
SERVED_MODEL_NAME=${SERVED_MODEL_NAME:-MiniMax-M2.7}
TP_SIZE=${TP_SIZE:-2}

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
    --host 0.0.0.0 \
    --port 30000 \
    --enable-metrics \
    --enable-cache-report \
    --log-requests \
    --log-requests-level 0 \
    --model-loader-extra-config '{"enable_multithread_load": true, "num_threads": 8}' \
    --tool-call-parser minimax-m2 \
    --reasoning-parser minimax-append-think \
    --context-length 131072 \
    --enable-mixed-chunk