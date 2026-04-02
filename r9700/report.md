# CPU 换型对 AMD RX 9700 GPU 性能影响报告

**GPU 平台**：AMD Radeon RX 9700 ×8（gfx1201，RDNA 4，PCIe Gen5）  
**CPU 变量**：AMD EPYC 9575F（基准） vs AMD EPYC 9655 downcore 84 核（待测）  
**测试日期**：9575F 基准 2026-04-01/02；9655 TBD  
**测试人**：AMD FAE  
**详细方法**：`methodology/h2d_benchmark.md`、`methodology/llm_benchmark.md`  
**原始数据**：`data/9575f/`、`data/9655/`（待补）

---

## 1. 执行摘要

### 核心问题

EPYC 9575F → 9655（downcore 84核）换型后，消费级 GPU（RX 9700）在以下两个维度的变化：

1. **PCIe H2D/D2H 带宽**：CPU PCIe Root Complex 路由能力、IOD 内部 FTI 链路分配是否随 SKU 变化
2. **LLM 推理吞吐**：短序列 TPOT 瓶颈在 PCIe AllReduce，CPU 互联配置是否能缓解

### 9575F 基准数据（已确认）

| 指标 | 9575F 实测值 | 说明 |
|------|------------|------|
| 正常 GPU H2D（单向，GPU 1-7） | **56 GB/s** | PCIe Gen5 x8 |
| **GPU 0 H2D（异常）** | **28.7 GB/s** | 约为正常值 50%，原因待查 |
| 跨 socket H2D（NUMA0→GPU4-7） | **37 GB/s** | xGMI 路径，较本地 -34% |
| 双向效率（单 GPU） | **73-79%** | FTI 非数据事务竞争，见 §3.3 |
| vLLM 短序列 TPOT（1k token） | **78 ms** | PCIe AllReduce 主导 |
| vLLM 峰值输出吞吐 | **239 tok/s** | ShareGPT 混合，并发 20 |

### 9655 待测项

| 待确认问题 | 测试方法 |
|-----------|---------|
| GPU 0 带宽异常是否与 CPU 有关 | 换 CPU 后重跑 TransferBench，对比 GPU 0 H2D |
| 同代 Turin PCIe/xGMI 配置是否一致 | 对比 GPU 1-7 单向带宽及跨 socket 带宽 |
| CPU 换型对 LLM AllReduce 延迟的影响 | 对比短序列（1k token）TPOT |
| 总体推理吞吐变化 | 重跑 ShareGPT 峰值吞吐测试 |

---

## 2. 测试平台

### 2.1 固定硬件（GPU 侧）

| 项目 | 规格 |
|------|------|
| GPU 型号 | AMD Radeon RX 9700（Device ID: 0x7551） |
| GPU 数量 | 8 |
| GPU ISA | gfx1201（RDNA 4） |
| 单卡 VRAM | 32 GB GDDR6 |
| 总 VRAM | 256 GB |
| GPU 互联 | PCIe（无 xGMI，消费卡） |
| PCIe 规格 | Gen5（正常卡 ~56 GB/s H2D，GPU 0 异常见 §3.1） |
| 系统内存 | 1.5 TB DDR5 |
| PCIe 拓扑 | 2P Turin：GPU 0-3 → Socket 0，GPU 4-7 → Socket 1 |

### 2.2 CPU 配置（变量）

| 项目 | 9575F（基准） | 9655（待测） |
|------|------------|-----------|
| 型号 | AMD EPYC 9575F | AMD EPYC 9655 |
| 核心数 | 64C/128T × 2 | downcore 84C × 2 |
| 频率 | 5.0 GHz（TurinHF） | — |
| PCIe Gen | Gen5 | Gen5 |
| xGMI 版本 | xGMI3 | xGMI3（同代，应一致） |
| IOD 数量 | 4 IOD/socket | 4 IOD/socket |
| 测试日期 | 2026-04-01/02 | TBD |

> **注**：9575F 与 9655 均属 Turin 平台，PCIe Gen5、xGMI3 规格相同，IOD 架构一致。
> 换型主要验证 PCIe Root Complex 路由配置和 BIOS 初始化差异。

### 2.3 软件栈

| 组件 | 版本 |
|------|------|
| OS | Linux（6.x kernel） |
| ROCm | 6.4 |
| PyTorch | 2.9.1+rocm6.4 |
| vLLM | 0.15.2.dev0+g1892993bc.d20260401.rocm640（源码编译） |
| TransferBench | v1.57（`/opt/rocm/bin/TransferBench`） |
| 测试模型 | DeepSeek-R1-Distill-Llama-70B（BF16，17 shards） |
| Python 环境 | ~/miniconda3/envs/rocm_vllm（conda，裸机，无 Docker） |

---

## 3. PCIe 带宽：H2D / D2H 测试

> **测试工具**：TransferBench v1.57（AMD 官方 nvbandwidth 等价物）  
> **传输大小**：256 MB per transfer（与 nvbandwidth 默认对齐）  
> **迭代**：warmup 3 + 正式 10 次取均值  
> **脚本**：`methodology/scripts/run_h2d_bench.sh`

### 3.1 单 GPU H2D/D2H 单向带宽

#### 9575F 基准（2026-04-02）

| GPU | NUMA | H2D (GB/s) | D2H (GB/s) | PCIe 状态 |
|-----|------|-----------|-----------|---------|
| GPU 0 | 0 | **28.72** | **27.62** | ⚠️ 异常：约正常值 50% |
| GPU 1 | 0 | 56.48 | 55.49 | 正常 |
| GPU 2 | 0 | 55.98 | 55.51 | 正常 |
| GPU 3 | 0 | 56.26 | 55.51 | 正常 |
| GPU 4 | 1 | 56.10 | 55.50 | 正常 |
| GPU 5 | 1 | 56.47 | 55.53 | 正常 |
| GPU 6 | 1 | 56.23 | 55.52 | 正常 |
| GPU 7 | 1 | 56.30 | 55.49 | 正常 |
| **正常均值** | | **56.26** | **55.51** | PCIe Gen5 x8 |

> **GPU 0 异常分析**：H2D 28.72 GB/s ≈ PCIe Gen5 x4 或 Gen4 x8 速率。
> 需用 `lspci -vv` 确认该槽实际 Link Speed / Link Width。
> 若换 9655 后恢复正常，则是 9575F BIOS/PCIe RC 初始化 bug。

#### 9655 对比（TBD）

| GPU | H2D (GB/s) | D2H (GB/s) | vs 9575F |
|-----|-----------|-----------|---------|
| GPU 0 | — | — | **关键对比点** |
| GPU 1-7 均值 | — | — | 预期无差异 |

### 3.2 多 GPU 并发 H2D（host_to_all_memcpy_ce 等价）

#### 9575F 基准

| 测试场景 | 各 GPU 带宽 (GB/s) | 聚合 (GB/s) | 说明 |
|---------|-----------------|-----------|------|
| NUMA0 → GPU 0-3（同 socket） | 28.8 / 55.7 / 56.0 / 55.7 | 112.7 | GPU0 拖累，理论 224 GB/s |
| NUMA1 → GPU 4-7（同 socket） | 55.7 / 55.6 / 55.7 / 55.6 | 210.5 | 接近满速 |
| NUMA0 → GPU 4-7（跨 socket） | 37.2 / 37.1 / 37.2 / 37.1 | 141.2 | **xGMI 开销 -34%** |
| 全 8 GPU（各就近 NUMA） | 28.8 / 55.7×6 / 55.6 | 224.7 | GPU0 异常持续存在 |

#### 9655 对比（TBD）

| 测试场景 | 聚合 (GB/s) | vs 9575F |
|---------|-----------|---------|
| NUMA0 → GPU 0-3 | — | — |
| NUMA1 → GPU 4-7 | — | — |
| 跨 socket | — | — |
| 全 8 GPU | — | — |

### 3.3 单 GPU 双向带宽（H2D + D2H 同时）

#### 9575F 基准

| GPU | 单向 H2D | 单向 D2H | 双向 H2D | 双向 D2H | 双向聚合 | H2D 效率 |
|-----|---------|---------|---------|---------|---------|---------|
| GPU 0 | 28.72 | 27.62 | 21.08 | 24.52 | 45.60 | 73% |
| GPU 1 | 56.48 | 55.49 | 41.91 | 50.85 | 92.76 | 74% |
| GPU 2 | 55.98 | 55.51 | 44.45 | 49.81 | 94.26 | 79% |
| GPU 3 | 56.26 | 55.51 | 41.78 | 50.84 | 92.62 | 74% |
| GPU 4 | 56.10 | 55.50 | 44.10 | 50.35 | 94.45 | 79% |
| GPU 5 | 56.47 | 55.53 | 41.92 | 50.32 | 92.25 | 74% |
| GPU 6 | 56.23 | 55.52 | 44.21 | 50.36 | 94.57 | 79% |
| GPU 7 | 56.30 | 55.49 | 42.20 | 49.37 | 91.57 | 75% |

> **双向效率 73-79%** 与 SCET-26230 结论完全吻合：双向流量引入非数据事务（Request/Response TLP）
> 与数据 TLP 竞争 PCIe 链路，导致效率下降约 20-25%。  
> GPU 2/4/6（奇数序 IOD 象限）效率约 79%，GPU 1/3/5/7 约 74%，存在 IOD 内部 FTI 路径差异。  
> **此特性由 Turin IOD 架构决定，换 CPU 不会改变。**

### 3.4 全 8 GPU 双向并发（host_to_all_bidirectional_memcpy_ce 等价）

#### 9575F 基准

| GPU | H2D 并发 (GB/s) | D2H 并发 (GB/s) | 聚合 (GB/s) | H2D 效率 vs 单向 |
|-----|--------------|--------------|-----------|--------------|
| GPU 0 | 21.06 | 24.77 | 45.83 | 73% |
| GPU 1 | 36.21 | 48.86 | 85.08 | 64% |
| GPU 2 | 44.37 | 50.47 | 94.84 | 79% |
| GPU 3 | 35.20 | 52.56 | 87.76 | 63% |
| GPU 4 | 36.03 | 48.35 | 84.37 | 64% |
| GPU 5 | 34.75 | 46.47 | 81.22 | 62% |
| GPU 6 | 33.81 | 52.83 | 86.64 | 60% |
| GPU 7 | 32.53 | 49.99 | 82.52 | 58% |
| **总聚合** | | | **648.3** | |

> **全并发双向时 H2D 效率进一步下降至 58-79%**，比单 GPU 双向（73-79%）更差，
> 说明全并发时存在跨 GPU 的 FTI 链路争用（SCET-26230 Observation 2）。
> GPU 2 保持最高效率（79%），GPU 7 最低（58%）——推测与 IOD 象限内 FTI 路径占用度相关。

### 3.5 带宽测试关键对比点汇总

| 测试项 | 9575F | 9655 预期 | 待确认 |
|--------|-------|---------|------|
| GPU 0 单向 H2D | **28.7 GB/s** | ? | 最重要 delta：若恢复 56GB/s 则是 CPU bug |
| GPU 1-7 单向 H2D 均值 | 56.3 GB/s | 56 GB/s | 应无差异 |
| 同 socket 4-GPU 聚合 H2D | 210.5 GB/s | 210 GB/s | 应无差异 |
| 跨 socket 4-GPU 聚合 H2D | 141.2 GB/s | 141 GB/s | xGMI 版本相同 |
| 单 GPU 双向效率 | 73-79% | 73-79% | 架构固有，应不变 |
| 全 8 GPU 双向聚合 | 648.3 GB/s | ~650 GB/s | 应无差异 |

---

## 4. LLM 推理性能测试

> **框架**：vLLM 0.15.2 ROCm（enforce-eager，NCCL_P2P_DISABLE=1）  
> **模型**：DeepSeek-R1-Distill-Llama-70B（BF16，TP=8）  
> **重要限制**：gfx1201 CUDA Graph 存在 HSA bug，强制 enforce-eager；AITER 仅支持 gfx9，此测试走 Triton 后端  
> **脚本**：`methodology/scripts/start_server.sh` + `methodology/llm_benchmark.md`

### 4.1 序列长度扫描（9575F 基准）

| 序列（input/output） | 并发 | TTFT mean (ms) | TPOT mean (ms) | Output (tok/s) | 瓶颈分析 |
|--------------------|------|----------------|----------------|----------------|---------|
| 1k / 256（短） | 10 | 2,863.8 | **78.3** | 112.0 | PCIe AllReduce + enforce-eager |
| 3k / 512（中短） | 10 | 6,111.1 | **86.2** | 101.9 | PCIe AllReduce 主导 |
| 6k / 512（中） | 10 | 11,899.0 | 131.9 | 64.5 | Attention 开始参与 |
| 12k / 512（中长） | 5 | 15,194.6 | 129.8 | 31.4 | Attention+AllReduce 混合 |
| 25k / 256（长） | 5 | 35,005.9 | **389.7** | 9.5 | KV cache 读取主导（GDDR6带宽瓶颈） |

```
TPOT vs Context Length (enforce-eager, 8×RX9700, gfx1201):
  1k:   78ms  ████████
  3k:   86ms  █████████
  6k:  132ms  █████████████
 12k:  130ms  █████████████
 25k:  390ms  ███████████████████████████████████████

短序列 TPOT 约 80ms 是 PCIe AllReduce 硬下限，与序列长度无关。
```

> **TPOT 在短/中短序列（≤3k）几乎恒定在 78-86ms**：8 卡 TP AllReduce 走 PCIe，每个 decode step
> 都要做一次 ring-allreduce，PCIe Gen5 x8 链路（56 GB/s）是固定开销。
> 若 9655 的 xGMI 路由或 BIOS 配置优化了 PCIe 命令发射延迟，短序列 TPOT 可能有小幅改善。

### 4.2 峰值吞吐（ShareGPT 混合，9575F 基准）

**数据集**：ShareGPT_V3（1000 条，并发 20，request-rate=INF）

| 指标 | 值 |
|------|----|
| 总输入 token | 215,196 |
| 总输出 token | 185,480 |
| 请求吞吐 | 1.29 req/s |
| 输出吞吐 | **239.2 tok/s** |
| 峰值输出 | **320 tok/s** |
| TTFT mean | 420.7 ms |
| TTFT P99 | 1,632.8 ms |
| TPOT mean | 80.4 ms |
| TPOT P99 | 139.4 ms |
| 总耗时 | 775 s |

#### 9655 对比（TBD）

| 指标 | 9575F | 9655 | Delta |
|------|-------|------|-------|
| 输出吞吐 (tok/s) | 239.2 | — | — |
| TTFT mean (ms) | 420.7 | — | — |
| TPOT mean (ms) | 80.4 | — | — |

### 4.3 Goodput / SLO 扫描（9575F 基准）

**数据集**：ShareGPT_V3（300 条，并发 20）

| TTFT SLO | 输出 tok/s | Goodput (req/s) | TTFT mean (ms) | TPOT mean (ms) | 说明 |
|----------|-----------|----------------|----------------|----------------|------|
| 500 ms | 232.8 | 0.807 | 488.4 | 79.5 | 约 30% 请求超 SLO |
| 1000 ms | 275.9 | 1.376 | 206.6 | 65.5 | 显著提升，SLO 全满足 |
| 2000 ms | 275.5 | 1.348 | 207.6 | 65.5 | 与 1000ms 近似 |
| 5000 ms | 275.7 | 1.380 | 207.0 | 65.5 | 饱和，无进一步提升 |

> **关键结论**：TTFT SLO 从 500ms 放宽到 1000ms，吞吐提升 18%（233→276 tok/s）。
> 1000ms 以上趋于饱和，说明系统在此配置下已接近 compute bound。
> **SLO ≥ 1000ms 时 TPOT 降至 65ms（vs 79ms），说明 SLO 放宽后调度器批量更大，AllReduce 效率提升。**

### 4.4 LLM 性能关键对比点汇总

| 指标 | 9575F | 9655 预期 | 说明 |
|------|-------|---------|------|
| 短序列 TPOT（1k） | **78.3 ms** | 可能小幅降低 | PCIe AllReduce 延迟，取决于 xGMI 配置 |
| 峰值吞吐 | **239 tok/s** | 待测 | CUDA Graph bug 是主限制，与 CPU 无关 |
| Goodput（1000ms SLO） | **275.9 tok/s** | 待测 | — |
| vLLM 服务稳定性 | 3h+ 无崩溃 | — | 关注 9655 是否引入新的初始化问题 |

---

## 5. RX 9700 ×8 vs MI308X ×8：架构对比

> **前提**：模型不同（dense 70B vs MoE 671B），测试框架不同（vLLM vs SGLang），绝对性能数字不可直接比较。
> 此节聚焦**架构特性**差异，量化平台能力上限。

### 5.1 平台差异

| 维度 | RX 9700 ×8（本次） | MI308X ×8（携程，2026-03-16） |
|------|-------------------|------------------------------|
| GPU 定位 | 消费级 RDNA4 | 数据中心 CDNA3 |
| GPU ISA | gfx1201 | gfx942 |
| 单卡 VRAM | 32 GB GDDR6（672 GB/s） | 192 GB HBM3（5.3 TB/s） |
| 总 VRAM | 256 GB | 1.5 TB |
| GPU 互联 | PCIe Gen5 x8（无 xGMI） | xGMI（300 GB/s 双向/卡） |
| CUDA Graph | ❌ HSA bug（gfx1201） | ✅ 正常 |
| Attention 后端 | Triton（AITER 不支持 gfx1201） | AITER Flash Attention |
| ECC | ❌（消费卡） | ✅ |
| 测试模型 | DeepSeek-R1-70B（dense） | DeepSeek-V3.2（MoE 671B，激活~37B） |
| 框架 | vLLM 0.15.2 ROCm | SGLang v0.5.9 ROCm |
| 系统 CPU | EPYC 9575F ×2 | EPYC（TBD） |

### 5.2 短序列性能（≤2k tokens，并发 10-20）

| 指标 | RX 9700 ×8（R1-70B） | MI308X ×8（V3.2） |
|------|---------------------|------------------|
| TTFT mean | 2,864 ms | 780 ms |
| TPOT mean | **78 ms** | 123 ms |
| Output tok/s | 112 | 150 |
| 每卡 tok/s | **14.0** | **18.8** |

> RX9700 每卡 output tok/s 约为 MI308X 的 **74%**。  
> TPOT 反而低于 MI308X（78 vs 123ms）——因为 R1-70B（70B dense）参数量远小于 V3.2 MoE（671B）。  
> TTFT 差距来自：① enforce-eager Python kernel launch overhead；② 模型规模差异。

### 5.3 混合序列（ShareGPT，并发 20）

| 指标 | RX 9700 ×8（R1-70B，vLLM） | MI308X ×8（V3.2，SGLang） |
|------|---------------------------|--------------------------|
| QPS | 1.29 req/s | 1.57 req/s |
| TTFT mean | **421 ms** | 795 ms |
| TPOT mean | **80 ms** | 139 ms |
| Output tok/s | 239 | 205 |
| 每卡 tok/s | **29.9** | **25.6** |

> **RX9700 每卡吞吐反超 MI308X（29.9 vs 25.6）**：70B dense << 671B MoE 计算量，比较无意义。  
> 若按模型激活参数归一化：R1-70B 全激活，V3.2 激活 ~37B；MI308X 归一后 tok/s ≫ RX9700。

### 5.4 长序列（25k tokens，并发 5）

| 指标 | RX 9700 ×8（R1-70B） | MI308X ×8（V3.2，16k-32k） |
|------|---------------------|--------------------------|
| TPOT mean | **390 ms** | **88.6 ms** |
| Output tok/s | 9.5 | 118 |
| TPOT 差距 | — | **4.4×** |

> 长序列差距显著扩大（4.4×）。原因分析：
> - **KV cache 读取**：GDDR6 672 GB/s << HBM3 5.3 TB/s（7.9× 差距），长序列 decode attention 受内存带宽主导
> - **AITER vs Triton**：MI308X 用 AITER 专属 Flash Attention，对长 context 有额外优化
> - **enforce-eager**：Python kernel launch 在长序列大批次时放大

### 5.5 PCIe 带宽对比

| 维度 | RX 9700 ×8 | MI308X ×8 |
|------|-----------|---------|
| 单 GPU H2D（正常） | 56 GB/s（PCIe Gen5 x8） | N/A（xGMI 直接访问） |
| 8 GPU AllReduce 路径 | PCIe（ring-allreduce，有争用） | xGMI 300 GB/s 双向/卡 |
| AllReduce TPOT 开销 | ~78ms（短序列主导） | 可忽略 |

### 5.6 适用场景结论

| 场景 | RX 9700 ×8 | MI308X ×8 |
|------|-----------|---------|
| 70B 以下 dense，短序列 | ⚠️ 可用（AllReduce 瓶颈固定 78ms） | ✅ 推荐 |
| 混合序列（ShareGPT 风格） | ✅（小模型有吞吐优势） | ✅ 推荐 |
| 长序列（≥10k） | ❌（GDDR6 带宽不足） | ✅ 推荐 |
| MoE 大模型（V3/R1 full） | ❌ VRAM 不足（256GB < 671B 所需） | ✅（1.5TB HBM） |
| 生产稳定性 | ❌（无 ECC，CUDA Graph bug） | ✅ |
| 开发调试 / 预算受限 | ✅ | — |

---

## 6. 附录：gfx1201 已知软件限制

换 CPU 不影响以下问题，但为完整性记录：

| 问题 | 严重度 | 解决方案 |
|------|--------|---------|
| CUDA Graph HSA_STATUS_ERROR_MEMORY_APERTURE_VIOLATION | 🔴 | `--enforce-eager`（性能损失约 2-5×） |
| AITER 不支持 gfx1201（代码硬锁 gfx9 only） | 🔴 | 无（等待上游支持） |
| LDS 64KB 限制（kNumThreadsPerBlockMerge=1024 超限） | 🔴 | patch csrc/sampler.cu → 512 |
| libtorch_hip.so 符号链接缺失 | 🟡 | `ln -sf libtorch_cuda.so libtorch_hip.so` |
| AllReduce GPU page fault（NCCL_SHM_DISABLE=1 时） | 🟡 | 仅设 `NCCL_P2P_DISABLE=1`，**不**禁用 SHM |
| NumPy ≥ 2.3 与 Numba 不兼容 | 🟡 | `pip install "numpy<2.3"` |
