# LIKWID 对 AMD EPYC 的支持分析（Milan / Genoa / Turin）及与 AMDuProf 的对比

## 总体结论

LIKWID 对 AMD EPYC 全系列（Milan/Zen3、Genoa/Zen4、Turin/Zen5）均有**完整官方支持**，可在 HPC 集群中放心使用。其核心价值（Marker API 代码插桩、精确线程绑定、自带微基准测试）是 AMDuProf 没有的。相比 AMDuProf，LIKWID 在部分 uncore 指标（DC Fill 来源细分、xGMI 带宽、L3 miss latency 等）上有缺口，但两者可以互补使用。

---

## 第一部分：各代 EPYC 的支持详情

### Milan（EPYC 7003，Zen3）

**CPUID**：Family `0x19`（`ZEN3_FAMILY`），Model `0x01`（`ZEN3_RYZEN`）
代码路径（`src/perfmon.c:1368`）：
```c
case ZEN3_FAMILY:
    case ZEN3_RYZEN:       // 0x01 ← Milan 走这条路
    case ZEN3_RYZEN2:      // 0x21
    case ZEN3_RYZEN3:      // 0x50
    case ZEN3_EPYC_TRENTO: // 0x30（HPC 定制版，accessDaemon 有独立处理）
        eventHash = zen3_arch_events;
```

注意：EPYC Milan 与 Zen3 Ryzen 共用同一 model ID（`0x01`）。

#### 计数器资源（`src/includes/perfmon_zen3_counters.h`）
- Core PMC：6 个（PMC0–PMC5），MSR `0xC001020x`
- L3 计数器：4 个（CPMC0–CPMC3）
- Data Fabric（Uncore）：4 个 DFC 计数器，映射 DRAM 通道
- 总计 20/21 个寄存器（有无 rdpmc 模式有差异）

#### 预置 group 清单（`groups/zen3/`）
| 文件 | 内容 |
|------|------|
| `CPI.txt` | 基础 CPI、IPC |
| `L2.txt` / `L2CACHE.txt` | L2 带宽、命中率 |
| `L3.txt` / `L3CACHE.txt` | L3 带宽（仅 load，无 store 事件） |
| `MEM1.txt` / `MEM2.txt` | DRAM 带宽（各 4 通道，需两次测量） |
| `NUMA.txt` | Local/Remote NUMA 流量（实验性） |
| `ENERGY.txt` | RAPL 功耗（Core + Package 域） |
| `FLOPS_DP.txt` / `FLOPS_SP.txt` | 浮点性能 |
| `BRANCH.txt` / `TLB.txt` / `CLOCK.txt` | 分支、TLB、频率 |

#### 主要限制
- Milan 有 **8 条 DDR4 内存通道**，但 DFC 计数器只有 4 个，必须分两次（MEM1 + MEM2）才能覆盖全部通道
- 内存带宽数据**仅在 NPS1 模式下准确**；NPS2/NPS4 下不可靠
- L3 事件只测 load 流量，无法测 store
- NUMA.txt 在 NPS2/NPS4 下语义变化，需谨慎解读

#### 实际使用示例
```bash
# 查看拓扑（CCD、CCX、NUMA 域）
likwid-topology -g

# 内存带宽（需运行两次取两组之和）
likwid-perfctr -C S0:0-31 -g MEM1 ./your_app
likwid-perfctr -C S0:0-31 -g MEM2 ./your_app

# CPI、L3 带宽、功耗
likwid-perfctr -C S0:0-31 -g L3 ./your_app
likwid-perfctr -C S0:0 -g ENERGY ./your_app

# Marker API 精确标记代码区域（编译加 -DLIKWID_PERFMON -llikwid）
likwid-perfctr -C S0:0-31 -g L3 -m ./your_instrumented_app
```

---

### Genoa（EPYC 9004，Zen4）

**CPUID**：Family `0x19`（ZEN3_FAMILY），Model `0x11`（`ZEN4_EPYC`）
代码路径：走 Zen4 分支，使用 `zen4_arch_events` / `zen4_counter_map`。

#### 计数器资源（`src/includes/perfmon_zen4_counters.h`）
- Core PMC：6 个
- L3：4 个 CPMC（per CCX）
- UMC：每 socket 12 个 UMC 控制器，每个 2 个计数器（Rd + Wr），通过 `MSR_AMD1A_UMC_PERFEVTSEL/PMC` 访问
- **与 Milan 的关键区别**：UMC MSR 直接计数 `CAS_CMD_RD/WR`，无需分组测量

#### 预置 group 清单（`groups/zen4/`）
与 Zen3 基本相同，MEM.txt 改为直接列出 UMC0C0~UMC11C0/C1：
```
BRANCH / CACHE / CLOCK / CPI / DATA / DIVIDE / ENERGY
FLOPS_DP / FLOPS_SP / ICACHE / L2 / L2CACHE / L3 / L3CACHE
MEM / NUMA / TLB
```

**MEM group 的改进**：一次覆盖全部 12 个 DDR5 通道，不受 NPS 模式限制，无需 MEM1+MEM2 分组。

#### Bergamo（EPYC 9004P，Zen4c）
- Model `0xA0`（`ZEN4_EPYC_BERGAMO`），独立路径，有 `groups/zen4c/` 目录

---

### Turin（EPYC 9005，Zen5）

**CPUID**：Family `0x1A`（`ZEN5_FAMILY`），Model `0x02`（`ZEN5_EPYC`）；Zen5c 版本 Model `0x11`（`ZEN5C_EPYC`）

#### 计数器资源（`src/includes/perfmon_zen5_counters.h`）
- Core PMC：6 个
- 总计数器数：`NUM_COUNTERS_ZEN5 = 33`（比 Zen4 略多）
- UMC：12 个控制器（每 socket），与 Zen4 相同机制

#### 预置 group 清单（`groups/zen5/`）
```
BRANCH / CLOCK / CPI / DATA / DIVIDE / ENERGY
FLOPS_BF16（新）/ FLOPS_DP / FLOPS_SP / ICACHE
L2CACHE / L3CACHE / MEM / TLB / TMA（新）
```

**新增 group**：
- **`TMA.txt`**：Top-down 微架构分析（Frontend_Bound / Backend_Bound / Retiring / Bad_Speculation / SMT contention）
- **`FLOPS_BF16.txt`**：Turin 原生支持 BF16 FMA 指令

**注意**：与 Zen4 相比，Zen5 的 `groups/` 中缺少 `L2.txt` 和 `NUMA.txt`（可能是事件定义变化导致尚未补充）。

---

### 三代对比速查表

| 功能 | Milan (Zen3) | Genoa (Zen4) | Turin (Zen5) |
|------|:---:|:---:|:---:|
| CPU 识别 | ✅ 0x19/0x01 | ✅ 0x19/0x11 | ✅ 0x1A/0x02 |
| Core PMC（6个） | ✅ | ✅ | ✅ |
| L3 PMC | ✅ | ✅ | ✅ |
| 内存带宽 MEM group | ⚠️ 需 MEM1+MEM2，仅 NPS1 准确 | ✅ 单次12通道 | ✅ 单次12通道 |
| NUMA Local/Remote 区分 | ✅ NUMA.txt | ✅ NUMA.txt | ❌ 无 NUMA.txt |
| Top-down TMA | ❌ | ❌ | ✅ TMA.txt（一级）|
| BF16 FLOPS | ❌ | ❌ | ✅ FLOPS_BF16.txt |
| RAPL 功耗 | ✅ | ✅ | ✅ |
| HSMP 接口 | ✅ | ✅ | ✅ |
| accessDaemon 白名单 | ✅ | ✅ | ✅ |
| IBS 事件定义 | ✅（事件文件有）| ✅（事件文件有）| ✅（事件文件有）|

---

## 第二部分：与 AMDuProf 的对比

AMDuProf 和 LIKWID 是**平行关系**，都直接访问同一套 CPU PMC 硬件，不存在上下级关系。LIKWID 的 accessDaemon 与 AMDuProf 的 MSR 模式在底层机制上完全等价。

### 访问机制对比

| 维度 | LIKWID | AMDuProf |
|------|--------|----------|
| Core PMC | ✅ MSR直接/accessDaemon/perf_event | ✅ Perf模式/MSR模式 |
| L3 PMC | ✅ | ✅ |
| 内存带宽（UMC） | ✅ Zen4/5 via UMC MSR | ✅ Perf模式（需内核≥6.0）或MSR模式 |
| xGMI / PCIe / DMA | ❌ 事件已定义，无 group | ✅ 完整支持 |
| 进程级带宽（resctrl MBM） | ❌ | ✅ |
| 虚拟机内 DF PMC | ❌（与 AMDuProf 一致，硬件限制）| 同左 |
| Marker API（代码插桩） | ✅ **AMDuProf 没有** | ❌ |
| 线程绑定（likwid-pin） | ✅ **AMDuProf 没有** | ❌ |
| 微基准测试（likwid-bench） | ✅ **AMDuProf 没有** | ❌ |
| Roofline 建模 | ❌ | ✅ |
| HTML 报告 | ❌ | ✅ Zen3+ |

### 功能覆盖对比（按 AMDuProf 指标分类）

| AMDuProf 功能 | LIKWID 现状 |
|---|---|
| `-m ipc`（IPC/CPI/利用率）| ✅ CPI.txt、CLOCK.txt |
| `-m l3`（L3 访问/命中率）| ✅ L3.txt / L3CACHE.txt |
| `-m l3` Ave L3 Miss Latency | ❌ 不支持 |
| `-m memory`（UMC 通道带宽）| ✅ MEM.txt（Zen4/5），⚠️ MEM1+MEM2（Zen3）|
| `-m dc` DC Fill 来源7层细分 | ❌ 只有粗粒度 Local/Remote（NUMA.txt），事件文件中有细粒度事件但无 group |
| `-m swpfdc/-m hwpfdc` 预取效果 | ❌ 事件已定义，无 group |
| `-m pipeline_util`（Top-down）| ⚠️ 仅 Zen5 有 TMA.txt（一级），Zen4 无 group |
| `-m xgmi`（Socket 间互联）| ❌ Zen4/5 events.txt 中有 xGMI DF 事件，无 group |
| `-m pcie / -m dma / -m ccm_bw` | ❌ 完全缺失 |
| `-m fp`（FP 吞吐量）| ✅ FLOPS_DP.txt / FLOPS_SP.txt |
| `-m avx_imix`（指令宽度分布）| ❌ 无按宽度细分的 group |
| `-m cxl`（CXL 内存带宽，Zen5）| ❌ |
| Roofline 建模 | ❌ |

### 最容易补充的缺口

以下功能所需事件定义已在 `src/includes/perfmon_zen4/5_events.txt` 中存在，只需编写对应 `.txt` group 文件：

1. **DC Fill 来源细分 group**（Zen3/4/5 均可）：
   利用 `DEMAND_DATA_CACHE_FILLS_LOCAL_ALL`、`DEMAND_DATA_CACHE_FILLS_REMOTE_ALL`、`DEMAND_DATA_CACHE_FILLS_REMOTE_DRAM` 等事件，区分 Local/Remote/DRAM 三层来源，是 NUMA 诊断最有价值的指标。

2. **xGMI group**（Zen4/5）：
   `EVENT_DATA_BW_CAKE_XGMI_0~3` 等 DFC 事件已在 Zen5 events.txt 中，可测量 socket 间互联出站带宽。

3. **Zen4 TMA group**：
   `DISPATCH_STALLS_PER_SLOT_FRONTEND/BACKEND` 已在 Zen4 events.txt 中定义，直接复用 Zen5 的 TMA.txt 格式即可。

4. **Zen5 NUMA group**：
   需确认 Zen5 中 `DATA_CACHE_REFILLS_LOCAL/REMOTE` 事件可用性后补充。

### 推荐两工具互补策略

```bash
# 系统级 uncore 视图（AMDuProf 负责）
AMDuProfPcm -m memory,l3,dc,xgmi -a -A system,package -d 60 &

# 应用级精确计数 + Marker API（LIKWID 负责）
likwid-perfctr -C S0:0-95 -g TMA -m ./your_app
```

- **AMDuProf 负责**：内存带宽全景、DC Fill 来源层级、xGMI 互联流量、L3 miss latency
- **LIKWID 负责**：Marker API 精确标注代码区域、线程绑定、自带微基准测试、TMA 一级分析

---

## 第三部分：访问模式选择（HPC 集群）

| 模式 | 要求 | 推荐度 |
|------|------|--------|
| `direct` | root 权限，MSR 设备可读写 | 开发测试用 |
| `accessdaemon` | setuid daemon，最安全 | **HPC 生产环境推荐** |
| `perf_event` | Linux perf_event 子系统，普通用户可用 | 容器/受限环境 |

EPYC 服务器集群中，建议使用 `accessdaemon` 模式，配合 `likwid-accessD`。

## 第四部分：不支持的功能

以下功能在所有代 EPYC 上均不支持：
- **AMD IBS（Instruction Based Sampling）**：AMDuProf CLI 支持，LIKWID 未实现（事件文件有 `TAGGED_IBS_OPS` 事件定义，但无采样机制）
- **AMD GPU 监控（EPYC 侧）**：ROCm GPU 有独立支持（`src/rocmon.c`），与 CPU EPYC 分开
- **Infinity Fabric 频率控制**：通过 BIOS/HSMP 控制，`likwid-setFrequencies` 仅针对 CPU 核心频率
- **Roofline 建模**：需要手动结合 FLOPS group 和 MEM group 数据自行计算
- **CXL 内存带宽**（Turin 特有）：AMDuProf 已支持，LIKWID 尚无实现
