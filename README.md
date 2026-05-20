# SGLang Prefill–Decode Disaggregation

基于 [SGLang](https://github.com/sgl-project/sglang) 推理引擎的 LLM 服务部署脚本，提供两套对照部署方案：

- **PD-Disaggregation（双节点）**：将 prefill 与 decode 两个阶段拆到不同节点上独立扩缩容，KV cache 通过 mooncake-over-RDMA 在两节点之间传输，由 `sglang_router` 充当统一入口。
- **Mix（单节点）**：经典的 prefill+decode 同节点部署，作为对照基线。

仓库还附带一组 RDMA / 容器辅助脚本，用于在不同硬件型号、不同网卡厂商（Mellanox / Broadcom bnxt_re / AMD Pensando ionic ……）的集群上快速把容器拉起来并验证 RoCE 互通。

---

## 1. 仓库内容

| 文件                   | 用途                                                                                                       |
| -------------------- | -------------------------------------------------------------------------------------------------------- |
| `start_container.sh` | 通用 RDMA 容器启动器：自动探测 `docker` / `podman`、自动透传宿主机 RDMA provider `.so` 进容器并注册到 `libibverbs`                  |
| `check_rdma.sh`      | 单节点 RDMA 自检：列出 IB 设备状态，并在容器内尝试用 `mori.io` 打开一次 RDMA backend                                              |
| `check_rdma_link.sh` | 双节点 RoCE 互通检查：默认对自动选出的数据面 NIC（与 `run_prefill.sh` / `run_decode.sh` 探测逻辑一致）逐张跑 `ibv_rc_pingpong`         |
| `run_prefill.sh`     | 在 prefill 节点容器内启动 prefill server                                                                         |
| `run_decode.sh`      | 在 decode 节点容器内启动 decode server                                                                           |
| `run_proxy.sh`       | 启动 `sglang_router`，作为对外的 OpenAI 兼容入口，把请求按 PD 分离路由到对应实例                                                  |
| `run_mix.sh`         | 单节点 mix 模式部署，作为对照基线                                                                                     |

所有脚本中的可调项都通过环境变量暴露，默认值放在脚本头部，按需 export 覆盖即可（汇总见 §3.4）。

---

## 2. 环境准备

### 2.1 硬件 / 系统假设

- 两台具备 RoCE v2 RDMA 网卡的 GPU 节点（脚本默认按 AMD ROCm + 8×RDMA NIC 调优，但容器启动器对厂商无强依赖）。
- 宿主机已加载对应厂商内核驱动（`mlx5_core` / `bnxt_re` / `ionic` ……）且至少一个端口 `state == ACTIVE`。
- 两节点之间数据面 IP 三层可达（`ping` 通即可）。
- 宿主机有可用的容器运行时（`docker` **或** `podman` 均可，脚本会自动探测）。

### 2.2 拉起容器

`start_container.sh` 会自动：扫描 `/sys/class/infiniband/*` 找到对应厂商的 provider `.so`，先 stage 到宿主机临时目录、整目录绑挂进容器、再由容器内安装到 `libibverbs` 的标准搜索路径并写入 `/etc/libibverbs.d/<vendor>.driver`。同一份脚本可在 Mellanox / Broadcom / AMD Pensando 等不同硬件上工作。

```bash
# 默认配置（自动选 docker / podman）
bash start_container.sh

# 常见自定义
IMAGE=lmsysorg/sglang-rocm:v0.5.11-rocm720-mi35x-20260514 \
CONTAINER=sglang-rdma \
EXTRA_MOUNTS="-v /path/to/models:/data/models" \
CONTAINER_CMD=podman \
    bash start_container.sh
```

启动完成后进入容器：

```bash
podman exec -it sglang-rdma bash   # 或 docker exec
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

默认会按驱动分组、自动只测数据面 NIC（管理 / 公网 NIC 会被自动跳过）。如需强制覆盖，用 `NICS=a,b,c bash check_rdma_link.sh ...`（白名单）或 `SKIP_NICS=a,b bash check_rdma_link.sh ...`（再排除几张）。

---

## 3. PD-Disaggregation 部署

### 3.1 拓扑

```
                +---------------------+
   client  -->  |   proxy / router    |  (sglang_router, OpenAI-compatible)
                |   :8000             |
                +----+--------+-------+
                     |        |
            HTTP+元数据      HTTP+元数据
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
- KV cache 通过 mooncake 走 RDMA 直接从 prefill 拷到 decode；控制面（ZMQ / bootstrap）走 TCP。
- `SGLANG_HOST_IP` / `MC_TCP_BIND_ADDRESS` 用来把 sglang 注册给 mooncake 的 `rank_ip` 与控制面绑到**数据面网段**，避免被默认路由带去公网 / 管理 NIC（详见 §3.4）。

### 3.2 启动顺序

> 三个进程都需要在 `start_container.sh` 拉起的容器内执行。

**Step 1 – prefill 节点**

```bash
export MODEL_PATH=/data/models/MiniMax-M2.7
export SERVED_MODEL_NAME=MiniMax-M2.7
export TP_SIZE=2

bash run_prefill.sh
```

**Step 2 – decode 节点**

```bash
export MODEL_PATH=/data/models/MiniMax-M2.7
export SERVED_MODEL_NAME=MiniMax-M2.7
export TP_SIZE=2

bash run_decode.sh
```

decode 端不需要预先知道 prefill 的地址 —— 每个请求经 router 派发时会携带 prefill 的 bootstrap 元数据。

两个 server 都启动后，日志末尾会出现 `The server is fired up and ready to roll!`，再继续 Step 3。

**Step 3 – proxy（任一可同时 HTTP 访问 prefill/decode 的节点，通常与 prefill 同机）**

```bash
# 注意：URL 必须使用 prefill / decode 启动时绑定的 *数据面* IP；
# proxy 会把这个 IP 作为 bootstrap_host 透传给 decode。
export PREFILL_URL=http://<prefill-node-data-plane-ip>:30000
export DECODE_URL=http://<decode-node-data-plane-ip>:30001

bash run_proxy.sh
```

### 3.3 发送请求

router 暴露 OpenAI 兼容接口（默认 `0.0.0.0:8000`）：

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

确认 PD 真的分流到两节点（可选）：

```bash
# 节点 1（prefill）日志只应看到 Prefill batch
grep -v HEALTH_CHECK /tmp/prefill.log | grep "Prefill batch" | tail
# 节点 2（decode）日志只应看到 Decode batch
grep -v HEALTH_CHECK /tmp/decode.log  | grep "Decode batch"  | tail
```

### 3.4 主要可调环境变量

| 变量                       | 默认值                                        | 适用脚本                                        | 说明                                                                 |
| ------------------------ | ------------------------------------------ | ------------------------------------------- | ------------------------------------------------------------------ |
| `MODEL_PATH`             | `/path/to/model`                           | `run_prefill.sh` / `run_decode.sh` / `run_mix.sh` | 本地模型权重路径                                                           |
| `SERVED_MODEL_NAME`      | `MiniMax-M2.7`                             | 同上                                          | 对外暴露的 model 名（`/v1/...` 请求里用）                                      |
| `PREFILL_URL`            | `http://prefill-host:30000`                | `run_proxy.sh`                              | prefill 数据面 URL                                                    |
| `DECODE_URL`             | `http://decode-host:30001`                 | `run_proxy.sh`                              | decode 数据面 URL                                                     |
| `PREFILL_BOOTSTRAP_PORT` | `8998`                                     | `run_proxy.sh` / `run_prefill.sh`           | mooncake bootstrap 端口（两边须一致）                                       |
| `IMAGE` / `CONTAINER`    | `lmsysorg/sglang-rocm:...` / `sglang-rdma` | `start_container.sh`                        | 镜像名 / 容器名                                                          |

### 3.5 Mix 模式（对照基线）

单节点同时承担 prefill + decode：

```bash
export MODEL_PATH=/data/models/MiniMax-M2.7
bash run_mix.sh
# 监听 0.0.0.0:30000，OpenAI 兼容
```

### 3.6 完整 e2e 示例（2 节点 MI355X + 8×ionic + 2×bnxt_re）

> 下面以一次实际跑通的部署作为参考。**模型目录请按你自己的集群替换**；数据面 IP（`10.2.144.x`）和镜像版本与目标集群一致，可以直接用。
>
> 模型 `MiniMax-M2.7` 共约 130 个 fp8 shards。
>
> 假设两台节点各开了一个常驻 SSH 终端，下面用 `[mi355-gpu-3] $` / `[mi355-gpu-25] $` 标注每条命令应该在哪一侧执行。**除"拉容器"那一步在宿主机上跑外，其余命令都在容器内执行**（先 `podman exec -it sglang-rdma bash` 进容器，或单条命令前加 `podman exec sglang-rdma bash -lc "..."`）。

| 角色 | 主机 | 数据面 IP |
| --- | --- | --- |
| prefill + proxy | `mi355-gpu-3`  | `10.2.144.9`  |
| decode          | `mi355-gpu-25` | `10.2.144.10` |

下文示例需要的环境变量，**两侧（宿主机 + 容器）终端都先各 export 一份**（值相同）：

```bash
export REPO=/path/to/sglang_pd_disag        # 仓库路径（两节点共享或各自 clone）
export MODELS=/path/to/models               # 含 MiniMaxAI/MiniMax-M2.7 的目录
export IP_A=10.2.144.9                      # mi355-gpu-3  数据面 IP
export IP_B=10.2.144.10                     # mi355-gpu-25 数据面 IP
```

**1. 两节点各拉容器**（在 **宿主机** 上执行；模型目录用 `EXTRA_MOUNTS` 挂入容器内 `/data/models`）

```bash
[mi355-gpu-3]  $ cd $REPO && EXTRA_MOUNTS="-v $MODELS:/data/models" bash start_container.sh
[mi355-gpu-25] $ cd $REPO && EXTRA_MOUNTS="-v $MODELS:/data/models" bash start_container.sh
```

然后两边各开一个容器内终端：

```bash
[mi355-gpu-3]  $ podman exec -it sglang-rdma bash
[mi355-gpu-25] $ podman exec -it sglang-rdma bash
```

> 下面所有命令都在 **容器内** 终端执行。

**2. 单节点 + 双节点 RDMA 自检**（脚本默认只测数据面 NIC，2 张 bnxt_re 管理 NIC 自动跳过；期望 8 对 ionic NIC 全部 `PASS`）

```bash
[mi355-gpu-3]  $ cd $REPO && bash check_rdma.sh
[mi355-gpu-25] $ cd $REPO && bash check_rdma.sh

[mi355-gpu-3]  $ cd $REPO && bash check_rdma_link.sh server      # 阻塞等待 client
[mi355-gpu-25] $ cd $REPO && PEER_IP=$IP_A bash check_rdma_link.sh client
```

**3. 起 prefill / decode**（前台启动；如想后台，自行加 `nohup ... &` 或重定向到 `/tmp`）

```bash
[mi355-gpu-3]  $ cd $REPO && \
    MODEL_PATH=/data/models/MiniMaxAI/MiniMax-M2.7 SERVED_MODEL_NAME=MiniMax-M2.7 \
    TP_SIZE=2 bash run_prefill.sh

[mi355-gpu-25] $ cd $REPO && \
    MODEL_PATH=/data/models/MiniMaxAI/MiniMax-M2.7 SERVED_MODEL_NAME=MiniMax-M2.7 \
    TP_SIZE=2 bash run_decode.sh
```

**4. 等两边日志都出现 `The server is fired up and ready to roll!` 再起 proxy**

```bash
# 新开一个 mi355-gpu-3 上的容器内终端：
[mi355-gpu-3]  $ cd $REPO && \
    PREFILL_URL=http://$IP_A:30000 DECODE_URL=http://$IP_B:30001 \
    bash run_proxy.sh
```

**5. 等 ~20s router worker 就绪后发请求验证**（任一节点均可，宿主机或容器内都行）

```bash
[mi355-gpu-25] $ curl -s -X POST http://$IP_A:8000/v1/chat/completions \
    -H "Content-Type: application/json" \
    -d '{
        "model": "MiniMax-M2.7",
        "messages": [{"role": "user", "content": "你好，请用一句话介绍一下你自己。"}],
        "max_tokens": 128,
        "stream": false
    }'
```

参考耗时（远端 NFS 加载）：冷启动 prefill ~40 min、decode ~9 min；二次启动有 page cache 后会明显加速。

---

## 4. 样例压测结果

```bash
# https://github.com/segnosys/light-trace-benchmark/tree/dev/xiaobo/agent
# prefill-decode disaggregation, both tp_size=2
# max_qps=2.0 max_inflight=30 system_prompt_len=0
python3 agent_throughput.py \
>   --server http://10.2.144.9:8000 \
>   --model MiniMax-M2.7 \
>   --tokenizer /shared/amdgpu/home/limou102_qle/models/MiniMaxAI/MiniMax-M2.7 \
>   --workload-config workloads/code_agent_128k.yaml \
>   --max-qps 2.0 \
>   --name agent-0
Loaded workload config from: workloads/code_agent_128k.yaml
  Applied: 23 parameters
  Skipped (CLI override): 2 parameters
    - max_qps (CLI override: 2.0)
    - tokenizer (CLI override: /shared/amdgpu/home/limou102_qle/models/MiniMaxAI/MiniMax-M2.7)
Loading tokenizer: /shared/amdgpu/home/limou102_qle/models/MiniMaxAI/MiniMax-M2.7
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
Server: http://10.2.144.9:8000
Model: MiniMax-M2.7
System prompt: 0 tokens
New tokens per request (mean / median): 2,500 / 1,000
Max prefix size (retirement): 120,000 tokens
Generation length (mean / median): 500 / 280
GPUs: 4
Ramp: 0.05 -> 2.00 QPS over 45s
Sustain: 2.00 QPS for 600s
Initial sessions: 4
New session rate: 4.0%
Max in-flight (backpressure): 30
Window size: 30s
================================================================================

Starting ramp: 0.05 -> 2.00 QPS over 45s
Then sustain 2.00 QPS for 600s
Backpressure: pause when in-flight > 30

[  77.2s] Prefill:        0 tok/s (1s) |   66,018 tok/s (30s) | Cache:  92.2% | Gen:   43.1 tok/s | Reqs:    65/   94 | In-flight:   29 | Errors:   0WARNING: Hit max_inflight (30) - traffic timing may diverge from seed (non-deterministic)
[ 610.8s] Prefill: 108,344,000 tok/s (1s) |   46,680 tok/s (30s) | Cache:  94.8% | Gen:   90.7 tok/s | Reqs:   534/  563 | In-flight:   29 | Errors:   [ 646.4s] Prefill:   44,800 tok/s (1s) |   46,661 tok/s (30s) | Cache:  94.0% | Gen:  131.2 tok/s | Reqs:   559/  589 | In-flight:   30 | Errors:   00

Waiting for remaining requests to complete...

Final Results:
--------------------------------------------------------------------------------
Total requests sent: 590
Completed: 590
Errors: 0
Success rate: 100.0%
Actual benchmark duration: 699.0s
Actual average QPS: 0.84 (target: 0.05 -> 2.00)

Actual Prompt Length Distribution:
  Mean: 68631 tokens
  Std Dev: 27268 tokens
  p50: 71268 tokens
  p90: 106784 tokens
  p99: 114847 tokens

Actual Generation Length Distribution:
  Mean: 458.1 tokens (target: 500)
  Median (p50): 296 tokens (target: 280)
  Std Dev: 554.1 tokens
  p90: 995 tokens
  p99: 2882 tokens

TTFT (Time to First Token):
  p50: 11726.8ms
  p90: 38871.6ms
  p99: 42960.4ms

TPOT (Time Per Output Token, excl. first):
  Samples: 559 (filtered: gen_len>1 & gen_time>=50ms)
  Mean: 27.7ms (36.1 tok/s/req)
  p50: 27.2ms
  p90: 39.2ms
  p99: 92.5ms

Peak Prefill Throughput:
  Total: 525,005 tokens/sec (31,500,300 tokens/min)
  Per GPU: 131,251 tokens/sec (7,875,075 tokens/min)

Average Throughput:
  Context: 868,955 tokens/min/GPU (14,483 tokens/sec/GPU)
  Generation: 53.5 tokens/sec (MTP compensated)
    (filtered 31 samples with generation_time < 50ms)

Cache Statistics:
  Ideal cache hit rate: 101.2% (assuming no eviction)
  Actual cache hit rate: 94.2%
  Cache efficiency: 93.1% (actual/ideal)
  Eviction rate: 6.9% of expected cache was evicted
  Total tokens: 40,492,053 (prefix: 40,969,725, cached: 38,123,632, evicted: 2,846,093)

Phase Throughput Breakdown (input TPM includes cache; uncached = actual prefill work):
  phase     dur(s)  reqs   qps    input TPM   cached TPM   uncached TPM  visible TPM  reason TPM  cache%  TTFT p50  TTFT p90  TPOT p50  TPOT p90
  ----------------------------------------------------------------------------------------------------------------------------------------------
  ramp        45.0    25  0.56      899,955      732,219        167,736          445       8,981   81.4%    308.2ms   1101.6ms     14.3ms     15.4ms
  sustain    600.0   533  0.89    3,769,408    3,558,868        210,540        1,134      23,327   94.4%  11307.5ms  38871.6ms     30.4ms     39.4ms
  drain       53.5    32  0.60    2,381,533    2,227,605        153,927          941      19,934   93.5%  35318.7ms  39158.3ms     18.0ms     19.3ms
  (per-GPU: divide TPM by 4)

ChatSession Statistics:
  Total sessions: 26
  Active: 14, Retired: 12
  Target new session rate: 4.0%
  Actual new session rate: 3.7%
  Final prefix sizes: min=12,909, max=120,000, mean=90,062
```
