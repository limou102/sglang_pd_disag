set -ex

# decode on a single known-good GPU (TP=1)
export HIP_VISIBLE_DEVICES="4"

# it seems some bug on this node, set it to lo otherwise NCCL error will occur
export NCCL_SOCKET_IFNAME=lo
python -m sglang.launch_server \
    --model-path Qwen/Qwen3-0.6B \
    --tp-size 1 \
    --mem-fraction-static 0.6 \
    --attention-backend aiter \
    --enable-mixed-chunk \
    --chunked-prefill-size 8192 \
    --max-prefill-tokens 16384 \
    --max-running-requests 64 \
    --disaggregation-mode decode \
    --disaggregation-transfer-backend mooncake \
    --port 30001
