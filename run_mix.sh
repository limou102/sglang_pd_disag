set -ex

python -m sglang.launch_server \
    --model-path Qwen/Qwen3-0.6B \
    --tp-size 1 \
    --mem-fraction-static 0.6 \
    --attention-backend aiter \
    --enable-mixed-chunk \
    --chunked-prefill-size 8192 \
    --max-prefill-tokens 16384 \
    --max-running-requests 64 \
    --port 30000
