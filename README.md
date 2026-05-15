# SGLang Prefill–Decode Disaggregation

基于 [SGLang](https://github.com/sgl-project/sglang) 推理引擎的 LLM 服务部署脚本，提供两套对照部署方案：

- **PD-Disaggregation（双节点）**：将 prefill 与 decode 两个阶段拆到不同节点上独立扩缩容，KV cache 通过 mooncake-over-RDMA 在两节点之间传输，由 `sglang_router` 充当统一入口。
- **Mix（单节点）**：经典的 prefill+decode 同节点部署，作为性能对照基线。

仓库还附带了一组 RDMA / 容器辅助脚本，用于在不同硬件型号、不同网卡厂商（Mellanox / Broadcom bnxt_re / AMD Pensando ionic ……）的集群上快速把容器拉起来并验证 RoCE 互通。

---

## 1. 仓库内容


| 文件                   | 用途                                                                               |
| -------------------- | -------------------------------------------------------------------------------- |
| `start_container.sh` | 通用 RDMA 容器启动器：自动探测宿主机的 RDMA NIC 厂商，把宿主机用户态 provider `.so` 透传进容器并注册到 `libibverbs` |
| `check_rdma.sh`      | 单节点 RDMA 自检：列出 IB 设备状态，并在容器内尝试用 `mori.io` 打开一次 RDMA backend                      |
| `check_rdma_link.sh` | 双节点 RoCE 互通检查：对每张 ACTIVE 的 NIC 跑一次 `ibv_rc_pingpong` 数据面握手                       |
| `run_prefill.sh`     | 在 prefill 节点容器内启动 prefill server                                                 |
| `run_decode.sh`      | 在 decode 节点容器内启动 decode server                                                   |
| `run_proxy.sh`       | 启动 `sglang_router`，作为对外的 OpenAI 兼容入口，负责把 prefill/decode 请求路由到对应实例                |
| `run_mix.sh`         | 单节点 mix 模式部署，作为对照基线                                                              |


所有脚本中的可调项都通过环境变量暴露，默认值放在脚本头部，按需 export 覆盖即可。

---

## 2. 环境准备

### 2.1 硬件 / 系统假设

- 两台具备 RoCE v2 RDMA 网卡的 GPU 节点（脚本默认按 AMD ROCm + 8×RDMA NIC 调优，但容器启动器对厂商无强依赖）。
- 宿主机已加载对应厂商内核驱动（`mlx5_core` / `bnxt_re` / `ionic` ……）且至少一个端口 `state == ACTIVE`。
- 两节点之间数据面 IP 三层可达（`ping` 通即可）。
- Docker 已安装。

### 2.2 拉起容器

`start_container.sh` 会自动扫描 `/sys/class/infiniband/`*、找到匹配的宿主机用户态 provider `.so`，并把它绑挂到容器内 `libibverbs` 会搜索的所有路径下，然后写入 `/etc/libibverbs.d/<vendor>.driver`。这样同一份脚本即可覆盖 Mellanox / Broadcom / AMD Pensando 等不同硬件。

```bash
# 默认配置
bash start_container.sh

# 常见自定义
IMAGE=lmsysorg/sglang-rocm:v0.5.11-rocm720-mi35x-20260514 \
CONTAINER=sglang-rdma \
EXTRA_MOUNTS="-v /data/models:/data/models" \
    bash start_container.sh
```

启动完成后进入容器：

```bash
docker exec -it sglang-rdma bash
```

> 若需要把模型目录挂入容器，在 `EXTRA_MOUNTS` 里追加对应 `-v` 即可。脚本默认已挂载 `$HOME` 与 `/mnt`。

### 2.3 RDMA 自检

容器内：

```bash
# 单节点：检查本机 RDMA / mori 是否可用
bash check_rdma.sh
```

两节点（建议在压测前执行一次，确保 RoCE 数据面跑得通）：

```bash
# 节点 1 (server)
bash check_rdma_link.sh server

# 节点 2 (client)
PEER_IP=<节点 1 数据面 IP> bash check_rdma_link.sh client
```

---

## 3. PD-Disaggregation 部署

### 3.1 拓扑

```
                +---------------------+
   client  -->  |   proxy / router    |  (sglang_router, OpenAI-compatible)
                |   :8000             |
                +----+--------+-------+
                     |        |
            HTTP+元数据     HTTP+元数据
                     |        |
        +------------v---+  +-v--------------+
        |  prefill node  |  |  decode node   |
        |  :30000        |  |  :30001        |
        |  bootstrap:8998|  |                |
        +-------+--------+  +-------+--------+
                |                   |
                +---KV via mooncake-+
                       (RDMA / RoCE)
```

- proxy 可与 prefill 同机部署，也可独立部署，只要能 HTTP 访问到两个 server。
- KV cache 通过 mooncake 走 RDMA 直接从 prefill 拷到 decode，控制面（ZMQ）走 TCP；`MC_TCP_BIND_ADDRESS` 用于把控制面绑到指定数据面网段，避免走错网卡。

### 3.2 启动顺序

> 三个进程都需要在 `start_container.sh` 拉起的容器内执行。

**Step 1 – prefill 节点**

```bash
# 必填：模型路径
export MODEL_PATH=/data/models/MiniMax-M2.7
export SERVED_MODEL_NAME=MiniMax-M2.7
export TP_SIZE=2

# 可选：覆盖默认 RDMA 网卡列表
# export IB_DEVICES=mlx5_0,mlx5_1,mlx5_2,mlx5_3

# 可选：手动指定 mooncake 控制面绑定的 IP（默认会从 10.2.x.x 网段自动挑一个）
# export MC_TCP_BIND_ADDRESS=10.2.0.11

bash run_prefill.sh
```

**Step 2 – decode 节点**

```bash
export MODEL_PATH=/data/models/MiniMax-M2.7
export SERVED_MODEL_NAME=MiniMax-M2.7
export TP_SIZE=2
# export IB_DEVICES=mlx5_0,mlx5_1,mlx5_2,mlx5_3
# export MC_TCP_BIND_ADDRESS=10.2.0.12

bash run_decode.sh
```

decode 端不需要预先知道 prefill 的地址 —— 每个请求经由 router 派发时会携带 prefill 的 bootstrap 元数据。

**Step 3 – proxy（任一可同时访问 prefill/decode 的节点，通常与 prefill 同机）**

```bash
export PREFILL_URL=http://<prefill-node-ip>:30000
export PREFILL_BOOTSTRAP_PORT=8998
export DECODE_URL=http://<decode-node-ip>:30001
# export PROXY_PORT=8000   # 默认 8000

bash run_proxy.sh
```

### 3.3 发送请求

router 暴露 OpenAI 兼容接口：

```bash
curl http://<proxy-host>:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "MiniMax-M2.7",
    "messages": [{"role": "user", "content": "你好，介绍一下你自己"}],
    "max_tokens": 256,
    "stream": false
  }'
```

### 3.4 主要可调环境变量


| 变量                  | 默认值              | 说明                            |
| ------------------- | ---------------- | ----------------------------- |
| `MODEL_PATH`        | `/path/to/model` | 本地模型权重路径                      |
| `SERVED_MODEL_NAME` | `MiniMax-M2.7`   | 对外暴露的 model 名（`/v1/...` 请求里用） |
| `TP_SIZE`           | `2`              | 张量并行度                         |


### 3.5 Mix 模式（对照基线）

单节点同时承担 prefill + decode：

```bash
export MODEL_PATH=/data/models/MiniMax-M2.7
bash run_mix.sh
# 监听 0.0.0.0:30000，OpenAI 兼容
```

---

## 4. 样例压测结果

```bash
# prefill-decode disaggregation, both tp_size=2
# max_qps=3.0 max_inflight=40
python3 agent_throughput.py   --server http://10.2.122.47:8000   --model MiniMax-M2.7   --tokenizer MiniMaxAI/MiniMax-M2.7   --workload-config workloads/code_agent_128k.yaml   --max-qps 3.0   --name sglang-agent-0 --max-inflight 40
Loaded workload config from: workloads/code_agent_128k.yaml
  Applied: 22 parameters
  Skipped (CLI override): 3 parameters
    - max_qps (CLI override: 3.0)
    - max_inflight (CLI override: 40)
    - tokenizer (CLI override: MiniMaxAI/MiniMax-M2.7)
Loading tokenizer: MiniMaxAI/MiniMax-M2.7
Tokenizer loaded successfully (vocab size: 200000)
Random seed set to: 1337
Running in TRAFFIC REPLAY mode
(Deterministic traffic, may have concurrent requests per session)
Press n to force next request to create a new session
Generating synthetic system prompt (0 tokens)...
System prompt generated: 0 tokens
Creating 4 initial session(s)...
Done. Starting with 4 session(s).
LLM Throughput Simulator (Growing ChatSession Prefixes)
--------------------------------------------------------------------------------
Server: http://10.2.122.47:8000
Model: MiniMax-M2.7
System prompt: 0 tokens
New tokens per request (mean / median): 2,500 / 1,000
Max prefix size (retirement): 120,000 tokens
Generation length (mean / median): 500 / 280
GPUs: 4
Ramp: 0.05 -> 3.00 QPS over 45s
Sustain: 3.00 QPS for 600s
Initial sessions: 4
New session rate: 4.0%
Max in-flight (backpressure): 40
Window size: 30s
================================================================================

Starting ramp: 0.05 -> 3.00 QPS over 45s
Then sustain 3.00 QPS for 600s
Backpressure: pause when in-flight > 40

[  62.1s] Prefill:        0 tok/s (1s) |   68,117 tok/s (30s) | Cache: 100.0% | Gen:   42.1 tok/s | Reqs:    57/   97 | In-flight:   40 | Errors:   0
WARNING: Hit max_inflight (40) - traffic timing may diverge from seed (non-deterministic)
[ 646.4s] Prefill:   21,049 tok/s (1s) |   52,198 tok/s (30s) | Cache:  97.7% | Gen:   62.0 tok/s | Reqs:   610/  650 | In-flight:   40 | Errors:   00
Waiting for remaining requests to complete...

Final Results:
--------------------------------------------------------------------------------
Total requests sent: 650
Completed: 650
Errors: 0
Success rate: 100.0%
Actual benchmark duration: 704.8s
Actual average QPS: 0.92 (target: 0.05 -> 3.00)

Actual Prompt Length Distribution:
  Mean: 68012 tokens
  Std Dev: 27177 tokens
  p50: 70545 tokens
  p90: 106403 tokens
  p99: 114847 tokens

Actual Generation Length Distribution:
  Mean: 434.9 tokens (target: 500)
  Median (p50): 298 tokens (target: 280)
  Std Dev: 511.1 tokens
  p90: 923 tokens
  p99: 2626 tokens

TTFT (Time to First Token):
  p50: 25300.7ms
  p90: 42974.0ms
  p99: 46934.7ms

TPOT (Time Per Output Token, excl. first):
  Samples: 624 (filtered: gen_len>1 & gen_time>=50ms)
  Mean: 31.7ms (31.5 tok/s/req)
  p50: 30.4ms
  p90: 43.6ms
  p99: 108.7ms

Peak Prefill Throughput:
  Total: 402,798 tokens/sec (24,167,880 tokens/min)
  Per GPU: 100,700 tokens/sec (6,041,970 tokens/min)

Average Throughput:
  Context: 940,851 tokens/min/GPU (15,681 tokens/sec/GPU)
  Generation: 48.6 tokens/sec (MTP compensated)
    (filtered 26 samples with generation_time < 50ms)

Cache Statistics:
  Ideal cache hit rate: 101.1% (assuming no eviction)
  Actual cache hit rate: 99.5%
  Cache efficiency: 98.4% (actual/ideal)
  Eviction rate: 1.6% of expected cache was evicted
  Total tokens: 44,207,528 (prefix: 44,690,092, cached: 43,983,308, evicted: 706,784)

Phase Throughput Breakdown (input TPM includes cache; uncached = actual prefill work):
  phase     dur(s)  reqs   qps    input TPM   cached TPM   uncached TPM  visible TPM  reason TPM  cache%  TTFT p50  TTFT p90  TPOT p50  TPOT p90
  ----------------------------------------------------------------------------------------------------------------------------------------------
  ramp        45.0    31  0.69    1,199,276    1,199,131            145          668      10,215  100.0%    165.8ms    219.7ms     16.8ms     18.8ms
  sustain    600.0   576  0.96    4,061,781    4,047,574         14,207        1,483      23,867   99.7%  24844.5ms  42369.6ms     34.3ms     43.9ms
  drain       59.5    43  0.72    2,711,880    2,629,180         82,699          980      20,212   97.0%  42806.5ms  44617.7ms     15.4ms     24.0ms
  (per-GPU: divide TPM by 4)

ChatSession Statistics:
  Total sessions: 27
  Active: 14, Retired: 13
  Target new session rate: 4.0%
  Actual new session rate: 3.5%
  Final prefix sizes: min=22,691, max=120,000, mean=94,178
```

