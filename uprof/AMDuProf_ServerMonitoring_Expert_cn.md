# AMDuProf 服务器监控：高级技术培训

> **目标读者：** 具备 AMD EPYC 微架构、PMC 理论及 Linux 性能子系统工作基础的性能工程师和 HPC 架构师。
> **参考资料：** AMD uProf 用户指南（文档编号 57368），第 4 章和第 5 章 —— *使用 AMDuProfPcm 进行性能表征* 与 *使用 AMDuProfPcm 进行性能建模*。

---

## 目录

1. [AMDuProfPcm 架构与 PMC 层次结构](#1-amduprofpcm-架构与-pmc-层次结构)
2. [EPYC 微架构预备知识](#2-epyc-微架构预备知识)
3. [数据采集内部机制：Perf 模式与 MSR 模式](#3-数据采集内部机制perf-模式与-msr-模式)
4. [多路复用理论与测量精度](#4-多路复用理论与测量精度)
5. [跨 Zen 代际的指标分类体系](#5-跨-zen-代际的指标分类体系)（5.1 代际矩阵 / 5.2 系统级监控指标 / 5.3 程序级优化指标）
6. [CLI 核心参数与命令参考](#6-cli-核心参数与命令参考)（采集范围 / 输出聚合 / 实机对比）
7. [内存子系统深度剖析：Data Cache Fill、L3 Miss Latency 与内存带宽](#7-内存子系统深度剖析data-cache-filll3-miss-latency-与内存带宽)（7.1 DC Fill 来源 / 7.2 预取效率 / 7.3 L3 Miss Latency / 7.4 内存带宽 / 7.5 进程级内存带宽 / 7.5.4 PCM 与 MBM 差异根因）
8. [互联结构监控：xGMI、PCIe、DMA、CXL、CCM](#8-互联结构监控xgmipciedmacxlccm)
9. [自顶向下流水线利用率分析（Zen 4 / Zen 5）](#9-自顶向下流水线利用率分析zen-4--zen-5)
10. [Roofline 建模与算术强度分析](#10-roofline-建模与算术强度分析)
11. [虚拟化与容器约束](#11-虚拟化与容器约束)
12. [高级诊断工作流](#12-高级诊断工作流)
13. [生产监控：告警、仪表盘与集成](#13-生产监控告警仪表盘与集成)
14. [自定义配置文件与原始 PMC 事件监控](#14-自定义配置文件与原始-pmc-事件监控)
15. [输出格式与后处理](#15-输出格式与后处理)
16. [已知限制与 BIOS 交互](#16-已知限制与-bios-交互)
17. [真实案例研究](#17-真实案例研究)
18. [附录：按 Zen 代际划分的指标快速参考](#18-附录按-zen-代际划分的指标快速参考)
19. [EPYC 9645 实机输出速查（AMDuProfPcm v5.1.756）](#19-epyc-9645-实机输出速查amduprofpcm-v51756)

---

## 1. AMDuProfPcm 架构与 PMC 层次结构

AMD uProf 由三个独立子系统组成，理解它们的边界可避免工具误用：

```
┌─────────────────────────────────────────────────────────────────┐
│                         AMD uProf                               │
│                                                                 │
│  ┌──────────────────┐  ┌───────────────┐  ┌──────────────────┐ │
│  │  性能分析器       │  │  功耗分析器    │  │  AMDuProfPcm     │ │
│  │  Performance     │  │  Power        │  │  (系统 PCM)      │ │
│  │  Profiler        │  │  Profiler     │  │                  │ │
│  │                  │  │               │  │ Core + L3 + DF   │ │
│  │ TBP / EBP / IBS  │  │ RAPL MSRs     │  │ uncore 计数器     │ │
│  │ 逐 IP 采样        │  │ 功耗/温度/    │  │ 内存/互联/       │ │
│  │ PMC 计数          │  │ 频率/P-state  │  │ 结构带宽         │ │
│  └──────────────────┘  └───────────────┘  └──────────────────┘ │
└─────────────────────────────────────────────────────────────────┘
```

AMDuProfPcm 是**系统级性能表征**工具。与 CPU 分析器（进程/采样粒度）不同，它暴露完整的 uncore PMC 层次结构，是服务器级吞吐量和互联结构分析的正确工具。

### 1.1 三个 PMC 域

| 域 | 硬件单元 | 作用域 | 典型指标 |
|-----|---------|-------|---------|
| **Core PMC** | 每逻辑 core 计数器 | core 微架构事件 | IPC、CPI、FP 吞吐量、cache hit/miss、TLB 缺失、pipeline utilization |
| **L3 PMC（uncore）** | 每 CCX 的 L3 计数器 | CCX 共享的 L3 缓存 | L3 访问次数、L3 miss rate、average miss latency |
| **DF PMC（uncore）** | 每 socket 数据互联计数器 | 跨 CCX 及片外流量 | 每 UMC 通道内存带宽、xGMI、PCIe、DMA、CXL、CCM |

**关键架构含义：** DF PMC 仅宿主机可访问。在虚拟机内部，虚拟机监控程序出于安全隔离会屏蔽 DF PMC 访问，导致内存带宽和互联结构指标无法从 VM 内部获取。

### 1.2 AMDuProfPcm 与 AMDuProfCLI 指定程序时的区别

两个工具都可以在启动时指定一个程序，但观察视角完全不同：

| | AMDuProfPcm `-- <app>` | AMDuProfCLI `collect -- <app>` |
|-|----------------------|-------------------------------|
| **观察视角** | 系统角度看程序行为 | 程序角度看自身性能 |
| **测量对象** | 整台机器的硬件计数器 | 目标进程的采样 / PMC 事件 |
| **归因粒度** | 系统、socket、CCX、core 级别 | 函数、源码行、指令级别 |
| **指定程序的目的** | 让程序跑起来，同时测量系统状态 | 对这个进程做采样和计数归因 |
| **回答的问题** | "内存带宽饱和了吗？跨 socket 流量高吗？" | "哪个函数耗时最多？哪里发生 cache miss？" |
| **输出** | 时间序列 CSV / HTML，系统聚合数据 | 逐函数热点报告，代码标注 |

**两者定位互补：**
- **PCM** — 程序是"触发者"，机器是被观测对象。关心程序对硬件资源的**消耗和影响**。发现**现象**（带宽饱和、cache miss 率高）。
- **CLI** — 程序本身是被观测对象。关心程序内部的**执行行为和热点**。定位**根因**（是哪个函数、哪行代码造成的）。

**分析策略：** 将 AMDuProfPcm 与工作负载**并行**运行获取系统级视图，再用逐进程 EBP 定位问题代码：

```bash
# 终端 1 —— 系统级计数器
AMDuProfPcm -m ipc,l3,memory -a -d 60 -o /tmp/pcm.csv &

# 终端 2 —— 逐进程微架构分析
AMDuProfCLI collect --config assess -p $(pgrep myapp) -d 60 -o /tmp/ebp
# 交叉对比：UMC 带宽高 + IPC 低 → 内存瓶颈
# UMC 带宽正常 + IPC 低 → 计算stall或分支问题
```

---

## 2. EPYC 微架构预备知识

### 2.1 Zen 4（9004 系列）拓扑结构

```
Socket（插槽）
├── CCD 0–3（Die 0）              CCD 4–7（Die 1）
│   └── CCX 0（8 core，32 MB L3）
│   └── CCX 1（8 core，32 MB L3）   ↕ xGMI（Die 间互联）
│   └── CCX 2（8 core，32 MB L3）
│   └── CCX 3（8 core，32 MB L3）
└── I/O Die（I/O 芯片）
    ├── 12 通道 DDR5（UMC 0–11）
    └── PCIe 5.0 / CXL 1.1
```

AMDuProfPcm 中的 `-c` / `-a` / `-A` 选项直接映射到此层次结构（见第 6 节）。

### 2.2 延迟参考数据（Zen 4）

| 访问层级 | 延迟 |
|---------|------|
| L1 数据缓存 | ~4 时钟周期 |
| L2 缓存 | ~14 时钟周期 |
| L3（本地 CCX） | ~33 时钟周期 |
| L3（同 Die 远端 CCX） | ~60–80 时钟周期 |
| L3（远端 Die / CCD） | ~100–120 时钟周期 |
| 本地 DRAM | ~70 ns（~190 周期 @ 2.7 GHz） |
| 远端 NUMA DRAM | ~130–160 ns |

这些数字是解读 Data Cache Fill 来源分布和 L3 miss latency breakdown的参考基准。

### 2.3 NPS 模式与 NUMA 拓扑

| NPS 模式 | NUMA 节点数/Socket | 内存通道数/NUMA | 适用场景 |
|---------|------------------|--------------|---------|
| NPS=1 | 1 | 12 | 延迟敏感、工作集较小 |
| NPS=2 | 2 | 6 | 均衡场景 |
| NPS=4 | 4 | 3 | 吞吐量敏感、NUMA 感知型应用 |

> AMDuProfPcm 中的 `DC Fills From Remote Memory PTI` 直接映射到跨 NUMA 流量。NPS=4 会放大 NUMA 不敏感代码的惩罚，但对 NUMA 感知代码能最大化带宽。

### 2.4 分析模式选择

| 模式 | 机制 | 开销 | 精度 | 最适合 |
|------|------|------|------|-------|
| **TBP** | OS 定时器 | < 1% | 函数级 | 初步热点分类 |
| **EBP** | Core PMC 采样 | 2–5% | 函数 + 源码 | 微架构瓶颈识别 |
| **IBS** | 硬件指令标记 | 3–7% | 逐指令 | 精确缓存/TLB/延迟归因 |
| **AMDuProfPcm** | uncore DF/UMC/L3 计数器 | < 1% | 全系统 | 内存带宽、跨 CCX 流量、互联负载 |
| **Power** | RAPL MSR（1 ms 分辨率） | 可忽略 | Socket/Core | 温控节流、TDP 饱和 |

---

## 3. 数据采集内部机制：Perf 模式与 MSR 模式

### 3.1 Perf 模式（仅 Linux，默认）

AMDuProfPcm 使用 Linux `perf_event` 子系统作为 PMC 仲裁器。

**优势：**
- 无需 root 权限（需 `perf_event_paranoid ≤ 0`）。
- 内核对并发分析器实例进行 PMC 硬件多路复用 —— 多个 AMDuProfPcm 会话、`perf stat` 等工具可安全共存。
- 支持**进程跟踪**：通过 `-p <pid>` 将 PMC 计数专属归因到目标 PID/TID。

**关键内核参数配置：**

> ⚠️ **生产环境须知**：以下参数调整会改变系统安全或稳定性设置，操作前需评估风险，操作后应及时恢复。所有 `echo ... > /proc/sys/...` 命令在重启后自动还原；若写入 `/etc/sysctl.conf` 则永久生效，生产环境**不建议**永久写入。

```bash
# ① 启用 DF PMC 采集（Perf 模式，Zen 4+，内核 ≥ 6.0）
# 默认值（Ubuntu）：1（仅 root 可读取内核事件）
# 设为 0 后：所有用户可访问硬件 PMC，存在信息泄露风险
# 生产建议：若有 root 权限可直接运行 AMDuProfPcm，无需修改此值（保持 ≥ 1）
echo 0 > /proc/sys/kernel/perf_event_paranoid
# 采集完成后恢复：
# echo 1 > /proc/sys/kernel/perf_event_paranoid

# ② 禁用 NMI 看门狗（释放一个 PMC 槽位给工具使用）
# 禁用后：内核 hard lockup 检测失效，若发生 CPU 死锁系统将无法自动重启
# 生产建议：短暂禁用，采集完成后立即恢复；soft lockup 检测不受影响
echo 0 > /proc/sys/kernel/nmi_watchdog
# 采集完成后恢复：
# echo 1 > /proc/sys/kernel/nmi_watchdog

# ③ 设置各 PMC 域的多路复用间隔（毫秒）
# 10ms 间隔会增加内核调度开销；生产建议使用默认值或 ≥ 100ms
echo 10 > /sys/devices/cpu/perf_event_mux_interval_ms        # Core
echo 10 > /sys/devices/amd_l3/perf_event_mux_interval_ms     # L3
echo 10 > /sys/devices/amd_df/perf_event_mux_interval_ms     # DF

# ④ 为大 core 数系统增加文件描述符上限（仅影响当前 shell 会话，非永久）
ulimit -n $(($(nproc) * 100))

# ⑤ 基准测试期间固定频率（仅用于对比测试，生产监控不需要）
# 注意：强制 performance 模式会禁用节能调节，增加功耗和发热
# 测试结束后恢复：cpupower frequency-set -g powersave（或原来的 governor）
cpupower frequency-set -g performance
```

> `/sys/devices/amd_l3/` 和 `/sys/devices/amd_df/` 路径取决于内核版本和 `amd_uncore` 内核模块。Zen 4+ 的 Perf 模式 DF 指标需要内核 ≥ 6.0。

### 3.2 MSR 模式

AMDuProfPcm 直接对 PMC MSR 编程，绕过 perf 子系统。

| 操作系统 | 访问机制 | 权限要求 |
|---------|---------|---------|
| Linux | 通过 `msr` 内核模块访问 `/dev/cpu*/msr` | Root，或通过 `AMDPcmSetCapability.sh` 授予能力 |
| Windows | 通过 `ioctl` 调用 AMDPowerProfiler 驱动 | 默认模式（安装时配置驱动） |
| FreeBSD | `cpuctl` 模块，`/dev/cpuctl*` | Root 或明确的设备权限 |

**Linux MSR 配置：**
```bash
# 加载 MSR 内核模块（允许访问 /dev/cpu*/msr 设备文件）
sudo modprobe msr

# 授予非 root 能力（每次启动执行一次）
# 该脚本通过 setcap 为 AMDuProfPcm 二进制文件授予 CAP_SYS_RAWIO 等能力
# 使普通用户无需 sudo 即可运行（替代 perf_event_paranoid=0 的更安全方案）
sudo /opt/AMDuProf_<version>/bin/AMDPcmSetCapability.sh
# 新终端中即可无 sudo 运行
```

**MSR 模式注意事项：**
- 最小采样间隔：1000 ms —— 无法实现亚秒级粒度。
- 开销较大：采集的样本数可能偏离 `持续时间 / 间隔`。
- 极低 L3 访问次数时，L3 miss rate可能虚假超过 100%（噪声放大）。
- 不支持进程跟踪；不能与其他分析器共享 PMC。
- 多个并发 MSR 模式实例使用 `-r`（强制重置）→ **未定义行为**。
- 主要在旧内核（< 5.x）缺乏 Perf 模式 L3/DF PMC 支持时使用。

---

## 4. 多路复用理论与测量精度

当请求的事件数超过可用硬件 PMC 槽位时，AMDuProfPcm 将其分组并轮询计数器。

### 4.1 多路复用约束

```
采样间隔（Logging Interval）≥ 多路复用间隔（Mux Interval）× 事件组数
                [AMDuProfPcm 会自动将 -I 向上取整至最近的有效倍数]
```

| 参数 | CLI 选项 | 默认值 | 建议 |
|-----|---------|-------|------|
| 多路复用间隔 | `-t <ms>` | 内核默认 | ≥ 100 ms；越小越精确但开销越大 |
| 采样间隔 | `-I <ms>` | 1000 ms | 必须是 `-t × 事件组数` 的整数倍 |

### 4.2 精度影响

不在 PMC 上的事件期间数据通过**外推**上次已知计数获得。噪声随以下因素增大：
- **工作负载波动性** —— 突发型负载受外推误差影响更大。
- **多路复用间隔长度** —— 间隔越长，外推越粗糙。
- **事件组数量** —— 组数越多，每组占用 PMC 的时间比例越低。

**最佳实践 —— 监控前先固定工作负载：**
```bash
taskset -c 2 ./myapp &
AMDuProfPcm -m ipc,l2,l3 -c core=2 -t 100 -I 1000 -o /tmp/out.csv
```

> 由于多路复用，`pipeline_util` 指标可能不一致。将被监控应用绑定到特定 core 集并只监控这些 core，可获得最佳结果。

---

## 5. 跨 Zen 代际的指标分类体系

### 5.1 功能 / 代际矩阵

在任何大规模部署前，对照此矩阵检查目标 SKU，并在采集器中添加相应守卫逻辑：

```bash
# 在目标节点上验证能力
AMDuProfCLI info --system | grep -E "(Family|Model|Features)"
```

| 功能 | Zen 2 | Zen 3 | Zen 4 | Zen 5 |
|-----|:-----:|:-----:|:-----:|:-----:|
| **── 高频诊断指标（生产环境最常用）──** | | | | |
| **`-m memory`**（DF PMC，内存总/读/写带宽 + Local/Remote DRAM 区分，逐通道 Ch-A~L） | ✓ | ✓ | ✓ | ✓ |
| **`-m umc`**（UMC PMC，逐 UMC 控制器 Est 带宽，Zen 5 独有；与 `-m memory` 互补） | — | — | — | ✓ |
| **`-m l3`**（L3 Access / Miss% / **Ave L3 Miss Latency**） | ✓ | ✓ | ✓ | ✓ |
| **`-m dc`**（DC Fill 来源分布，含 **Remote DRAM Read %**） | — | ✓ | ✓ | ✓ |
| &nbsp;&nbsp;&nbsp;↳ `-m swpfdc`（软件预取触发的 DC Fill 来源细分） | — | ✓ | ✓ | ✓ |
| &nbsp;&nbsp;&nbsp;↳ `-m hwpfdc`（硬件预取器触发的 DC Fill 来源细分） | — | ✓ | ✓ | ✓ |
| **`-m xgmi`**（Socket 间 xGMI 互联带宽） | — | — | ✓ | ✓ |
| **`-m ccm_bw`**（CCX 跨 Socket 读写带宽） | — | — | ✓ | ✓ |
| **`-m pcie`**（PCIe 读写带宽，本地/远端） | — | — | ✓ | ✓ |
| **── 补充诊断指标 ──** | | | | |
| `-m ipc`（IPC / CPI / 利用率 / 有效频率） | ✓ | ✓ | ✓ | ✓ |
| `-m l1` / `-m l2` / `-m cache_miss` / `-m tlb` | — | ✓ | ✓ | ✓ |
| `-m dma`（上游 DMA 带宽） | — | — | ✓ | ✓ |
| `-m pipeline_util`（自顶向下 Frontend/Backend/Retiring） | — | — | ✓ | ✓ |
| `-m fp`（SSE/AVX FLOPs，Mixed Stall） | — | — | ✓ | ✓ |
| `-m avx_imix`（512/256/128-bit SIMD 指令比例） | — | — | ✓ | ✓ |
| `-m cxl`（CXL 内存带宽） | — | — | — | ✓ |
| **── 报告与工具特性 ──** | | | | |
| CSV 报告 | ✓ | ✓ | ✓ | ✓ |
| Roofline 建模（`roofline` 子命令） | ✓ | ✓ | ✓ | ✓ |
| HTML 报告 | — | ✓ | ✓ | ✓ |
| 虚拟化支持（Hypervisor 内 Core PMC） | — | ✓ | ✓ | ✓ |

### 5.2 系统级监控指标概览

这组指标面向**整机/集群健康监控**，无需指定程序，直接反映硬件资源状态。是日常运维和问题初诊的第一手段。

| 指标（`-m`） | PMC 域 | 核心输出 | 典型诊断问题 |
|------------|--------|---------|------------|
| **`memory`** | DF | Total/Rd/Wr Bw（GB/s），逐通道（Ch-A~L），Local/Remote DRAM Write | 内存带宽是否饱和？读写比是否异常？ |
| **`umc`** | UMC | Est Mem Bw/Rd/Wr（GB/s），逐 UMC 控制器（Zen 5） | 各 UMC 通道是否负载均衡？ |
| **`l3`** | L3 | L3 Access/Miss/Hit%，Ave L3 Miss Latency（ns） | L3 命中率多少？Miss 后延迟多高？ |
| **`dc`** | Core | DC Fill 来源分布（Local L2/L3/CCX/DRAM），Remote DRAM Read % | 数据从哪里来？有多少跨 socket 远端 DRAM 访问？ |
| &nbsp;&nbsp;↳ `swpfdc` | Core | 软件预取触发的 DC Fill 来源（与 dc 列相同结构） | Remote DRAM Fill 高时，是否来自 `prefetchT*` 指令？ |
| &nbsp;&nbsp;↳ `hwpfdc` | Core | 硬件预取器触发的 DC Fill 来源 | Remote DRAM Fill 高时，是否来自硬件预取器？ |
| **`xgmi`** | DF | xGMI Outbound Data Bytes（GB/s），逐 socket | Socket 间互联链路流量多大？ |
| **`ccm_bw`** | DF | Local/Remote Inbound Read Data Bytes（GB/s） | CCX 间跨 socket 读取流量是否异常？ |
| **`pcie`** | DF | Total/Rd/Wr PCIe Bw（GB/s），Local/Remote 区分 | PCIe 设备（GPU/NIC/NVMe）带宽占用多少？ |
| **`dma`** | DF | Upstream DMA Read/Write（GB/s），Local/Remote | DMA 设备的内存访问流量 |
| **`cxl`** | DF | Total/Rd/Wr CXL Bw（GB/s）（Zen 5） | CXL 内存扩展设备带宽 |

**典型监控命令（系统级无负载可直接运行，无需指定程序）：**

```bash
# NUMA 带宽均衡诊断（最常用组合）
AMDuProfPcm -m memory,l3,dc -a -A system,package -d 30

# 互联结构监控
AMDuProfPcm -m xgmi,ccm_bw,pcie -a -A system,package -d 30

# Zen 5 UMC 通道均衡性排查
AMDuProfPcm -m umc --no-aggr -d 30
```

---

### 5.3 程序级优化指标概览

这组指标面向**单一程序的微架构优化**，需要结合工作负载运行，分析程序自身的执行效率。通常在已知存在性能问题后，用于定位根因。

#### `-m ipc`：执行效率基线

| 指标 | 公式 | 解读 |
|-----|------|------|
| **IPC** | `PMCx0C0 / PMCx076` | 每时钟周期退休指令数。Zen 4 理论峰值 ≈ 6；调优 HPC 实际 ≈ 4 |
| **CPI** | `1 / IPC` | 每指令消耗周期数，越低越好 |
| **Utilization (%)** | `(1 − idle/TSC) × 100` | Core 非空闲时间占比。低值 → 调度问题或功耗门控 |
| **Eff Freq (MHz)** | `(APERF/TSC) × P0Freq` | 含 C-state 转换的真实频率。偏低说明有节流 |
| **branch misprediction rate** | `mispred / retired branches` | Zen 4 惩罚 ~15–20 周期/次，目标 < 2% |
| **Locked Instructions (pti)** | 原子指令计数/千条指令 | 过高说明存在同步热点（锁争用） |

**IPC 解读速查：**

| IPC 范围 | 含义 |
|---------|------|
| > 3.0 | 良好：代码向量化好、缓存友好 |
| 1.5–3.0 | 正常：大多数服务型负载 |
| 0.8–1.5 | 警惕：可能有内存或分支瓶颈 |
| < 0.8 | 严重 stall：排查 cache miss 或序列化操作 |

#### `-m pipeline_util`：自顶向下瓶颈定位（Zen 4+）

将 pipeline 槽位按去向分类，快速定位瓶颈层级：

| 指标 | 含义 | 异常阈值（参考） |
|-----|------|----------------|
| **Frontend_Bound** | 取指/译码跟不上，pipeline 前端是瓶颈 | > 20% 值得关注 |
| **Backend_Bound.Memory** | 后端因内存访问延迟阻塞 | > 15% → 配合 `-m l3`/`dc` 诊断 |
| **Backend_Bound.CPU** | 后端因执行单元不足阻塞 | > 10% → 检查指令级并行度 |
| **Bad_Speculation** | 分支预测错误导致 pipeline 冲刷 | > 5% → 配合 `-m ipc` 的分支 miss rate |
| **Retiring** | 有效退休槽位占比，越高越好 | < 30% 说明整体效率差 |

#### `-m fp` / `-m avx_imix`：浮点与向量化质量（Zen 4+）

| 指标 | 工具 | 解读 |
|-----|------|------|
| **Retired SSE/AVX FLOPs (GFLOPs)** | `-m fp` | 硬件计数的 FP 吞吐量，Roofline 分析的基础 |
| **Mixed SSE/AVX Stalls (pti)** | `-m fp` | SSE↔AVX 切换惩罚（~70 周期/次），目标 = 0 |
| **Packed 512-bit FP Ops (%)** | `-m avx_imix` | AVX-512 占比，HPC 应尽量高 |
| **Scalar/MMX/x87 FP Ops (%)** | `-m avx_imix` | HPC 应接近 0，高值意味向量化机会缺失 |

> Zen 4 AVX-512 以两个融合 256 位操作执行，**无单核频率降低**。但全 socket 同时满载 AVX-512 会触及 TDP 上限，导致所有 core 频率一起下降。

#### `-m l1` / `-m l2` / `-m cache_miss` / `-m tlb`：缓存与 TLB 细节

通常在 `-m l3` 和 `-m dc` 确认存在缓存问题后，进一步下钻使用：

| 工具 | 关键指标 | 用途 |
|-----|---------|------|
| `-m l2` | L2 Miss from DC Miss (pti) | 确认 L1 miss 有多少穿透到 L2 |
| `-m cache_miss` | L1 DC Miss (pti), L2 Data Read Miss (pti) | 数据缓存 miss 的完整路径 |
| `-m tlb` | L1/L2 ITLB/DTLB Miss (pti) | 大内存工作集的地址翻译开销 |
| `-m swpfdc`/`hwpfdc` | 软/硬件预取来源分布 | 评估预取策略有效性 |

---

## 6. CLI 核心参数与命令参考

三个参数控制"采集范围"和"输出粒度"，是最容易混淆的选项。一句话区分：

- **`-c`** / **`-a`** — 决定**采集哪些核心**（数据来源）
- **`-A`** — 决定**如何展示输出**（汇总粒度）

### 6.1 采集范围：`-c` 与 `-a`

| 标志 | 采集范围 |
|-----|---------|
| `-a` | 全系统所有核心（最常用） |
| `-c core=N` | 单个逻辑 core N |
| `-c core=N-M` | core 范围 N 到 M |
| `-c ccx=N` | CCX N 内所有 core 及该 CCX 的 L3 PMC |
| `-c ccd=N` | CCD N 内所有 core |
| `-c package=N` | Socket N 内所有 core、L3、DF PMC |
| `-c numa=N` | NUMA 节点 N 内所有 core |

`-c` 与 `-a` 互斥，不能同时使用。

### 6.2 输出聚合：`-A`

| 标志 | 每采样周期输出行数 |
|-----|----------------|
| `-A system` | 1 行（所有核心汇总） |
| `-A package` | 每 socket 1 行 |
| `-A ccd` | 每 CCD 1 行 |
| `-A ccx` | 每 CCX 1 行 |
| `-A core` | 每逻辑 core 1 行 |
| `-A system,package` | 1 行系统汇总 + 每 socket 1 行 |

`-A` 与 `-a`/`-c` 可同时使用。例如：`-a -A system,package` 表示采集全部核心、同时输出整机和每 socket 的汇总行。

### 6.3 实机输出对比（AMD EPYC 9645，`-m ipc`）

**场景 1：`-a -A system` — 全系统单行汇总**

```bash
AMDuProfPcm -m ipc -a -A system -d 3
```

```
CORE METRICS
System (Aggregated)
Timestamp,Utilization(%),Eff Freq(MHz),IPC(Sys+User),IPC(User),CPI(Sys+User),CPI(User),L2 Access/cycle,L2 Miss/cycle,L2 Hit%
2025-08-01T13:08:04.591,22.07,1579.56,0.52,0.56,1.94,1.79,0.48,0.04,91.36
```

全系统只有 1 行，利用率 22.07%，IPC 0.52。适合快速确认系统整体状态。

---

**场景 2：`-a -A system,package` — 整机 + 每 socket 分行**

```bash
AMDuProfPcm -m ipc -a -A system,package -d 3
```

```
CORE METRICS
System (Aggregated),Package (Aggregated)-0,Package (Aggregated)-1
Timestamp,...
2025-08-01T13:08:12.618,22.10,1668.80,0.52,...,21.86,1674.96,0.52,...,22.34,1662.75,0.52,...
```

同一行输出三组数据：System / Pkg-0 / Pkg-1。若两个 socket 的利用率或带宽差异明显，说明存在 NUMA 不均衡。

---

**场景 3：`-c ccx=0 -A ccx` — 只采集 CCX 0**

```bash
AMDuProfPcm -m ipc -c ccx=0 -A ccx -d 3
```

```
CORE METRICS
CCX (Aggregated)-0
Timestamp,Utilization(%),Eff Freq(MHz),IPC(Sys+User),...
2025-08-01T13:08:22.019,16.06,1503.50,0.58,...
```

只采集并展示 CCX 0 的数据，用于分析绑定在该 CCX 上的单一进程。

---

**对比总结：**

| 命令 | 输出行数 / 采样 | 适用场景 |
|------|--------------|---------|
| `-a -A system` | 1 行 | 系统整体快速状态检查 |
| `-a -A system,package` | 1+N\_socket 行 | 发现跨 socket 不均衡 |
| `-a -A ccx` | N\_ccx 行（本机 16 个） | CCX 级热点定位 |
| `-c ccx=N -A ccx` | 1 行 | 单进程绑核精确分析 |
| `-a -A core` | N\_core 行（本机 192 个） | 逐核细粒度（数据量大，慎用） |

### 6.4 命令参考

```
AMDuProfPcm [options] -- <app>           # 从应用启动到退出的全程分析
AMDuProfPcm [options] -d <sec>           # 定时全系统采集
AMDuProfPcm top [options]                # 实时控制台（不支持 -A）
AMDuProfPcm roofline [options] -- <app>  # 采集 Roofline 数据
AMDuProfPcm profile [options]            # 时间序列 + 累积 + Roofline 一体化
AMDuProfPcm hreport <dir>                # 从已有 CSV 生成 HTML 报告
AMDuProfPcm compare <dir1>,<dir2>        # 两次采集的回归对比报告
```

报告模式：默认输出时间序列；加 `-C` 改为累积汇总（适合稳态基准对比）。

---

## 7. 内存子系统深度剖析：Data Cache Fill、L3 Miss Latency 与内存带宽

### 7.1 Data Cache Fill 来源层次

当需求加载在 L1 Data Cache 中缺失时，Fill 从越来越远的位置提供。AMDuProfPcm 可以显示**按 Fill 来源计数**（PTI = 每千条指令）：

```
Data Cache Fill 来源（Zen 3 / Zen 4+）：
├── 本地 L2 缓存（同一 core）              ← ~4 周期
├── 同 CCX 内的 L3 或不同 L2             ← ~33–40 周期
├── 同 package/节点内不同 CCX            ← ~70–100 周期
├── 本地 DRAM / I/O                      ← ~80–190 周期
├── 远端 CCX 缓存（不同 socket）          ← ~200–300 周期
└── 远端 DRAM / I/O                      ← ~300–500+ 周期
```

**采集命令（无需指定 app，省略 `-d` 可持续运行）：**
```bash
AMDuProfPcm -m dc -a -A system,package -O /tmp/dc_out
```

**CSV 实际输出列结构（来自 EPYC 9645 Zen 5 实测）：**

每个聚合级别（System / Package-0 / Package-1）输出以下 14 列：

| 列名 | 含义 |
|------|------|
| `All DC Fills (pti)` | 全部 DC Fill 总计（含 prefetch 触发） |
| `DC Fills From Local L2 (pti)` | 来自同 core 本地 L2 |
| `DC Fills From Local L3 or different L2 in same CCX (pti)` | 来自同 CCX 内 L3 或其他 L2 |
| `DC Fills From another CCX in same node (pti)` | 来自同 Socket 内其他 CCX |
| `DC Fills From Local Memory or I/O (pti)` | 来自本地 DRAM |
| `DC Fills From another CCX in remote node (pti)` | 来自远端 Socket 的 CCX 缓存 |
| `DC Fills From Remote Memory or I/O (pti)` | 来自远端 Socket 的 DRAM |
| `Remote DRAM Reads %` | 远端 DRAM Fill 占全部 Fill 的比例 |
| `Demand DC Fills From ...`（以上6项的 Demand 子集） | 仅需求访问触发的 Fill，排除 prefetch |

> `All DC Fills` 包含 prefetch 触发的 Fill；`Demand DC Fills` 仅统计程序主动发出的 load 指令触发的 Fill。两者对比可判断 prefetch 是否在有效拉数据。

**健康基线示例（EPYC 9645 空载）：**
```
All DC Fills ≈ 5.9 pti
└── From Local L2:        5.87 pti  ← 约 99%，绝大多数命中本地 L2
    From Local L3/CCX:    0.04 pti
    From other CCX:       0.01 pti
    From Local DRAM:      0.00 pti
    From Remote DRAM:     0.00 pti
Remote DRAM Reads %:      0.01%    ← NUMA 完全健康
```

两个 Socket 数据对称，说明负载均衡、NUMA 访问正常。**生产环境中若 `Remote DRAM Reads %` 持续 > 5–10%，应立即排查 NUMA 亲和性。**

**诊断规则：** 关注填充来源的*分布*，而非仅看总miss rate：
- `DC Fills From Remote CCX` 高但 DRAM 填充不高 → 数据在 L3 但在错误的 CCX → 修复 socket 内的线程/数据亲和性。
- `DC Fills From Remote DRAM` 高 → 典型跨 socket NUMA 问题 → 使用 `numactl`、内存绑定。

**Zen 4+ 关键指标：Remote DRAM Read %**
```
= DC Fills From Remote Memory / All DC Fills × 100
```
延迟敏感型工作负载中该值 > 5–10% 表明存在严重的 NUMA 错置。

**修复措施：**
```bash
numactl --localalloc ./myapp                              # 将内存绑定到本地节点
numactl --cpunodebind=0 --membind=0 ./myapp              # 同时绑定 CPU 和内存
taskset -c 0-15 ./myapp                                  # 将线程保持在同一 CCX/Die
```

### 7.2 prefetch效率分析

`-m swpfdc` 和 `-m hwpfdc` 暴露prefetch-triggered fill在层次中的落点 —— 与需求填充相同的来源细分。

| 观察现象 | 诊断 | 操作 |
|---------|------|------|
| SwPfDC 来自远端 DRAM 高 | software prefetch跨越 NUMA 边界 | 优先修复 NUMA 放置 |
| HwPfDC 来自本地 DRAM 高，需求 DRAM 填充低 | hardware prefetch有效 | 无需操作 |
| 需求 DRAM 填充高 + HwPfDC 低 | hardware prefetch未覆盖访问模式 | 添加 `__builtin_prefetch` 或 `PREFETCHNTA` |
| BIOS prefetcher全部关闭 | HWPF 指标为空 | 使用 `swpfdc` 分析；添加显式software prefetch |

### 7.3 L3 miss latency 读取（`-m l3`，Zen 4+）

`-m l3` 输出的 `Ave L3 Miss Latency (ns)` 是 L3 miss 后整条请求路径（L3 判断 + 内存控制器排队 + DRAM 存取 + 数据返回）的**平均往返延迟**，并非纯 DRAM 访问延迟。

**`-m l3` 实际输出列（v5.1.756 实测）：**

| 列名 | 含义 |
|-----|------|
| `L3 Access` | 采样窗口内 L3 访问绝对次数 |
| `L3 Miss` | L3 miss 绝对次数 |
| `L3 Miss %` | miss 率 |
| `L3 Hit %` | hit 率 |
| `Ave L3 Miss Latency (ns)` | L3 miss 平均延迟（含 DRAM 访问全路径） |
| `Potential Mem Bandwidth Saving (GB/s)` | 若工作集能放入 L3 可节省的带宽估算 |

> **注意：** 联合 `-m ipc,l3` 时额外增加 `L3 Access (pti)` 和 `L3 Miss (pti)` 两列（per-thousand-instructions 归一化）。

---

#### 实验验证：用 multichase 交叉校验 `Ave L3 Miss Latency`

> **核心结论（先读）：** multichase 是测量内存访问延迟的基准工具。当工作集远超 L3 容量、L3 完全 miss 时，**L3 miss latency 就等于内存访问延迟**。用 PCM `-m l3` 同期监控，`Ave L3 Miss Latency` 与 multichase 的读数应高度吻合——两者测的是同一件事。

**multichase 的工作原理**

multichase 通过**指针追逐（pointer chasing）**构造出 CPU 无法预取的串行访问链：每次内存访问的地址来自上一次访问的结果，CPU 只能等待数据返回后才能发出下一条请求。这带来两个关键特性：

- **强制 L3 miss**：工作集（本实验 1 GB）远超 EPYC 9645 单 socket 的 L3 容量（192 MB），每次指针追逐都必然穿透 L3，直达 DRAM
- **测量纯内存延迟**：由于串行访问，带宽无法掩盖延迟，multichase 报告的就是从 CPU 发出请求到 DRAM 数据返回的完整往返时间

本实验命令各参数含义：

```
numactl -C 1 -m 0   → 绑定到 core 1，内存只分配在 NUMA 0（本地 DRAM，排除远端干扰）
multichase
  -H                → 使用 2 MB hugepage（避免 TLB miss 引入额外延迟，让结果更纯净）
  -s 512            → 指针步长 512 字节（跨越 cache line，防止空间局部性复用）
  -m 1g             → 工作集 1 GB（192 MB L3 的 5 倍以上，确保全部 miss）
  -n 60             → 运行 60 次迭代取平均
```

**操作步骤（AMD EPYC 9645，v5.1.756）：**

```bash
# 终端 1：运行 multichase
sudo numactl -C 1 -m 0 ./multichase -H -s 512 -m 1g -n 60

# 终端 2（同时运行）：采集 20 秒 l3 数据
sudo AMDuProfPcm -m l3 -a -A system,package -d 20
```

**实测结果：**

multichase 输出（单位 ns）：
```
107.6
```

PCM `-m l3` 同期采集（节选 3 行）：
```
L3 METRICS
System (Aggregated)                                                           Package (Aggregated)-0                                        Package (Aggregated)-1
L3 Access,   L3 Miss,  L3 Miss%,  L3 Hit%,  Ave L3 Miss Latency (ns), ...   Ave L3 Miss Latency (ns), ...   Ave L3 Miss Latency (ns), ...
15431466,    13846563,    89.73,    10.27,          107.09,            ...         105.20,             ...         403.09,             ...
15414220,    13770471,    89.34,    10.66,          106.91,            ...         105.07,             ...         463.80,             ...
15523871,    13837055,    89.13,    10.87,          107.21,            ...         105.33,             ...         460.04,             ...
```

**结论与解读：**

| 观测 | 数值 | 说明 |
|-----|-----|------|
| multichase 测得延迟 | **107.6 ns** | 本地 DRAM 访问延迟（全 L3 miss 条件下） |
| PCM System 级 Ave L3 Miss Latency | **≈ 107 ns** | 与 multichase 吻合 |
| PCM Pkg-0（workload 所在 socket） | **≈ 105 ns** | numactl `-m 0` 确保访问本地 DRAM |
| PCM Pkg-1（对侧 socket） | **≈ 450 ns** | 系统后台流量跨 xGMI 访问远端 DRAM |

两个工具数值高度吻合，验证了：**当 L3 Miss% 接近 100% 时，`Ave L3 Miss Latency` 就是内存访问延迟的直接读数**，无需其他换算。

> **Pkg-0 vs Pkg-1 的 4 倍差异**（105 ns vs 450 ns）直观反映了 NUMA 拓扑代价：本地 DRAM 约 100–120 ns，跨 socket xGMI 远端 DRAM 约 400–500 ns。生产环境中若系统级平均值明显高于 200 ns，需用 `-m dc` 确认 Remote DRAM Read 占比是否过高。

---

**解读与优化优先级：**

| Ave L3 Miss Latency | 解读 |
|---------------------|------|
| < 100 ns | 异常偏低（可能多路复用误差或工作集仍在 L3 内） |
| 100–150 ns | 主要由本地 DRAM 服务（正常，与 multichase 本地测量吻合） |
| 150–300 ns | 本地 DRAM + 部分远端 DRAM 混合 |
| > 350 ns | 大量远端 NUMA DRAM 服务 L3 miss → 检查 `-m dc` 的 `Remote DRAM Reads %` |

若要精确归因延迟来源（本地/远端 DRAM/CCX）：结合 `-m dc` 的 DC Fill 来源分布，可确定 L3 miss 中有多大比例流向远端 DRAM。

### 7.4 内存带宽（`-m memory`）

以 GB/s 报告每 UMC 通道的读写带宽，区分 Local / Remote DRAM，在 package 级别可用（`-A package`）。

```bash
AMDuProfPcm -m memory -a -A system,package -d 60 -O /tmp/membw
```

**Zen 4+ 关键输出：**
- `Total Memory Bw (GB/s)` —— 读写合计
- `Local DRAM Read/Write` 和 `Remote DRAM Read/Write`（GB/s）——判断 NUMA 流量比例

**EPYC 9654 参考值（DDR5-4800，12 通道）：**
- 理论峰值：`12 × 2 × 4800 MT/s × 8 B = 460 GB/s`
- 实测 STREAM 峰值：~380–400 GB/s；超过 300 GB/s 时应考虑缓存分块优化

### 7.5 进程级内存带宽：从系统视图到进程视图

`-m memory` 给出的是**系统全局带宽**，无法区分带宽来自哪个进程。当多个服务共存时，需要定位"哪个进程消耗了带宽"，这时需要引入 **Linux RDT MBM（Memory Bandwidth Monitoring）** 技术。

#### 7.5.1 技术原理：resctrl / RDT MBM

AMD EPYC（Zen 4 及以上）支持 Intel RDT 兼容接口，通过 Linux 内核的 `resctrl` 文件系统暴露 MBM 计数器。将目标进程的 PID 写入监控组的 `tasks` 文件，硬件即对该 PID 的内存访问单独计数。`mbm_local_bytes` 和 `mbm_total_bytes` 均为**累计字节计数器**，对同一指标间隔采样两次、用增量除以时间即得实时带宽：

```
带宽 (GB/s) = (V₂ - V₁) / Δt
```

`mbm_local_bytes` 只统计本地 NUMA 节点的访问字节数；`mbm_total_bytes` 同时包含远端 NUMA 流量。对于绑核在单 NUMA 节点运行的进程，轮询 `mbm_local_bytes` 即可；若需量化跨 NUMA 访问，则 `mbm_total_bytes - mbm_local_bytes` 即为远端流量。

**验证 MBM 支持：**
```bash
cat /sys/fs/resctrl/info/L3_MON/mon_features
# 输出应包含：mbm_total_bytes  mbm_local_bytes
```

#### 7.5.2 工具：process_mem_bandwidth_monitor.py

本培训附带的脚本 `training/amd-uprof-pcm-server-monitoring/process_mem_bandwidth_monitor.py` 封装了上述 resctrl 操作：按进程名或 PID 自动创建监控组、分配 PID、轮询带宽计数器，结束后自动清理。用法参见脚本内置的 `--help`。

#### 7.5.3 实验：numactl 绑定负载下的 PCM 与 MBM 对比

**实验环境：** AMD EPYC 9645（Zen 5，2 socket，192 cores），DDR5，24 通道

**负载：** 使用 `numactl` 将 stress-ng 严格绑定至 socket 0，使 PCM 的 package 级输出能清晰区分负载来源：

```bash
# 终端 1：启动 NUMA 绑定的内存负载（仅使用 socket 0 的 CPU 和内存）
sudo numactl --cpunodebind=0 --membind=0 \
    stress-ng --vm 2 --vm-bytes 80% --timeout 90s

# 终端 2：PCM 系统级监控
sudo AMDuProfPcm -m memory -a -A system,package -d 60

# 终端 3：进程级 MBM 监控（按进程名查找所有 stress-ng 相关 PID）
sudo python3 /home/zz/process_mem_bandwidth_monitor.py stress-ng --interval 1 --count 30
```

> **注意：** 传进程名（而非单个 PID）让脚本能找到主进程及其所有 worker 子进程；stress-ng `--vm` 会 fork 出多个子进程，监控时需全部覆盖。

**PCM 实测输出（稳态，AMD EPYC 9645，2026/03/09）：**

```
System (Aggregated):
  Total Mem Bw:   ~11.5 GB/s
  Remote DRAM Bw:   0.0 GB/s   ← numactl --membind=0 确保无跨 NUMA 流量

Package-0:
  Total Mem Bw:  ~11.5 GB/s  (Rd: ~0.83 GB/s, Wr: ~10.65 GB/s)
  Per channel (Ch-A~Ch-L): Rd ~0.06–0.09 GB/s, Wr ~0.88–0.89 GB/s

Package-1:
  Total Mem Bw:  ~0.02–0.03 GB/s   ← 几乎空闲，负载完全隔离在 socket 0
```

numactl 绑定效果明确：Package-0 承载全部写流量（~10.65 GB/s），Package-1 接近空闲，Remote DRAM = 0。

**process_mem_bandwidth_monitor.py（resctrl MBM）实测输出（AMD EPYC 9645，2026/03/09）：**

```
找到进程 'stress-ng': 匹配=[38271, 38272, 38273, 38274, 38275]，根=[38271]，含子进程共 5 个
已创建监控组: /sys/fs/resctrl/mon_groups/stress-ng_monitor
已分配 TID: 5 个（来自 5 个进程）
正在采集基准值...

进程: [38271, 38272, 38273, 38274, 38275]  |  监控组: stress-ng_monitor
Metric: mbm_local_bytes  |  间隔: 1.0s  |  活跃L3域: 2/16
==============================================
    时间          L3域#06      L3域#07    合计(MB/s)
----------------------------------------------
 22:23:43      5190.45     5166.54    10357.00
 22:23:44      5192.83     5165.46    10358.29
 22:23:45      5194.03     5162.84    10356.87
 22:23:46      5193.65     5164.77    10358.42
 22:23:47      5187.72     5166.54    10354.26
 22:23:48      5186.52     5163.28    10349.80
 22:23:49      5184.91     5162.36    10347.27
 22:23:50      5188.35     5162.24    10350.59
 22:23:51      5190.93     5169.28    10360.20
 22:23:52      5191.41     5162.16    10353.57
```

MBM 稳态 **~10,355 MB/s（≈10.35 GB/s）**，与 PCM 的 ~11.6 GB/s 相差约 **10%**，两者高度吻合。

#### 7.5.4 PCM 与 MBM 差异根因

两种工具的**测量位置**不同，这是数值存在约 10% 差距的根本原因：

```
CPU core
  │
  ├── L1/L2 cache
  │
  ├── L3 cache  ◄── resctrl MBM 在此计数（L3 miss 流量）
  │      │
  │      │  Non-Temporal Store 绕过 L3 ──────────┐
  │      ▼                                       │
  └──► UMC ◄──────────────────────────────────── ┘
         │    ◄── AMDuProfPcm -m memory 在此计数（物理总线全部流量）
         ▼
       DRAM
```

- **MBM（~10.35 GB/s）**：统计进程产生的 L3 miss 字节数，不含硬件 prefetch、cache line eviction 等系统流量
- **PCM（~11.6 GB/s）**：在 UMC（内存控制器）测量所有物理总线事务，包括 prefetch 流量和硬件一致性协议开销
- **差值（~1.2 GB/s）**：来自 prefetch 和系统级协议开销，不属于应用进程直接发起的内存访问

MBM 量化的是**进程实际发起的工作集带宽**，PCM 反映的是 **DRAM 物理总线总负载**，两者角度不同，均有价值。

需要注意的是，若负载使用 non-temporal store 指令（如 STREAM、高性能 benchmark 中的 `vmovntpd`），NT store 写操作绕过 L3 直接写入 DRAM，MBM 对此类写流量**完全不可见**：

| 负载类型 | MBM 写可见 | PCM 写可见 | 两者差异 |
|---------|-----------|-----------|---------|
| stress-ng vm（cacheable 写）| ✅ | ✅ | ~10%（prefetch/协议开销）|
| STREAM / memset（NT store）| ❌ | ✅ | 可达数倍 |

**本实验结论：**
- `numactl --cpunodebind=0 --membind=0` 将负载完全隔离至 socket 0：PCM 显示 Pkg-0 总带宽 ~11.6 GB/s（写 ~10.7 GB/s），Pkg-1 几乎空闲，Remote DRAM = 0
- MBM 捕获进程级带宽 **~10.35 GB/s**，与 PCM 差距约 10%，符合 prefetch 开销的预期
- 对不使用 NT store 的普通写负载，**MBM 可作为进程级带宽的可靠依据**；若负载使用 NT store（STREAM 等高性能 benchmark），MBM 会严重低估写带宽，此时以 PCM 为准

---

## 8. 互联结构监控：xGMI、PCIe、DMA、CXL、CCM

### 8.1 xGMI 带宽（`-m xgmi`）

按链路监控 socket 间 xGMI3 链路出站流量。GMI 利用率高意味着大量跨 Die 缓存或内存流量 —— CCX/NUMA 亲和性问题的信号。

```bash
AMDuProfPcm -m xgmi --collect-xgmi -a -A system,package -d 60 -O /tmp/xgmi
```

**不对称**的 xGMI 利用率高表明跨 socket 的线程/数据放置不均衡。

### 8.2 PCIe 带宽（`-m pcie`，`--collect-pcie`，Zen 2 / Zen 4 / Zen 5）

按 quad 的 PCIe 读写带宽，区分本地和远端：

```
Total PCIE Bandwidth (GB/s)
├── Total PCIE Rd/Wr Bandwidth Local (GB/s)
├── Total PCIE Rd/Wr Bandwidth Remote (GB/s)
└── Quad 0-3 PCIE Rd/Wr Bandwidth Local/Remote (GB/s)
```

用于 AI/ML 推理服务器中 GPU 到主机的数据传输分析。

### 8.3 DMA 带宽（`-m dma`，Zen 4 / Zen 5）

上行 DMA 流量（设备到内存），按本地/远端 socket 和读写方向拆分。对存储和网络密集型服务器表征至关重要。

### 8.4 CCM 带宽（`-m ccm_bw`，Zen 4+）

CPU 一致性调制器（CCM）监控 CPU core 复合体与数据互联结构边界处的流量。

| 指标 | 解读 |
|-----|------|
| Local Inbound Read Data Bytes (GB/s) | 从本地互联流入 CPU 的数据（DRAM 读） |
| Local Outbound Write Data Bytes (GB/s) | 从 CPU 流出至本地互联的数据（DRAM 写） |
| Remote Inbound/Outbound Bytes | 跨 socket 一致性流量 |

接口 0/1 的 CCM 指标为 CCM 负载均衡分析提供更细粒度的信息。

### 8.5 CXL 带宽（`-m cxl`，仅 Zen 5）

```
Total Est Mem Bw (GB/s)          → 总带宽（DRAM + CXL）
Total CXL Read Memory BW (GB/s)  → CXL 读带宽
Total CXL Write Memory BW (GB/s) → CXL 写带宽
```

用于评估 CXL 附加内存分层的有效带宽扩展效果。

---

## 9. 自顶向下流水线利用率分析（Zen 4 / Zen 5）

`-m pipeline_util` 指标组实现了**两级自顶向下微架构分析**，按dispatch slot暴露pipeline 瓶颈类别。

### 9.1 一级指标

dispatch slot（Zen 4 最多 6 个/周期）被穷举划分：

```
Total_Dispatch_Slots = 100%
├── SMT_Disp_contention    → SMT 线程竞争导致的槽位损失
├── Frontend_Bound         → frontend starvation（取指/解码/操作缓存）
├── Bad_Speculation        → bad speculation — wasted槽位（flushed uop）
├── Backend_Bound          → 执行stall（内存或执行单元）
└── Retiring               → 有效工作（retired operations）← 唯一有生产价值的类别
```

### 9.2 二级指标

| 一级分类 | 二级子类 | 根因 |
|---------|---------|------|
| Frontend_Bound | **Latency（延迟）** | iCache 缺失、ITLB 缺失 —— 长时间重填stall 整个 frontend |
| Frontend_Bound | **BW（带宽）** | 解码宽度或操作缓存取指带宽饱和 |
| Bad_Speculation | **Mispredicts（预测失误）** | branch prediction失败 —— Zen 4 每次flush惩罚 ~15–20 周期 |
| Bad_Speculation | **Pipeline_Restarts（pipeline restart）** | 自修改代码或序列化指令导致的重同步 |
| Backend_Bound | **Memory（内存）** | L1/L2/L3 missstall、DRAM 延迟、TLB 缺失页表遍历 |
| Backend_Bound | **CPU（计算）** | ALU/FP 端口压力、执行单元争用 |
| Retiring | **Fastpath（快速路径）** | 高效单周期dispatch路径 |
| Retiring | **Microcode（微码）** | 微码辅助指令（rep mov、复杂 FP 操作） |

### 9.3 分类诊断决策树

```
第一步：AMDuProfPcm -m pipeline_util,ipc,l3,memory -a -A system -C -O /tmp

Frontend_Bound.Latency 较高（> 15%）？
  → -m l1（iCache miss rate），-m tlb（ITLB miss rate）
  → 修复：PGO、为代码段使用大页、链接时优化

Frontend_Bound.BW 较高（> 10%）？
  → 操作缓存带宽饱和（代码密度问题）
  → 修复：减少循环展开、LTO 改善代码布局

Bad_Speculation.Mispredicts 较高（> 10%）？
  → 交叉对比 -m ipc 中的 Branch Mis-prediction Ratio
  → 修复：无分支 SIMD 比较、剖析引导式分支提示

Backend_Bound.Memory 较高（> 25%）？
  → -m dc、-m l2、-m l3 排查缺失来源层次
  → 检查 Remote DRAM Read % 是否存在 NUMA 不均衡
  → 评估 -m swpfdc 与 -m hwpfdc 的prefetch coverage

Backend_Bound.CPU 较高（> 20%）？
  → -m fp 检查 FP 端口压力，-m avx_imix 检查 SIMD 宽度
  → 修复：指令调度、依赖链分析

Retiring.Microcode 较高（> 5%）？
  → 微码辅助风暴（VZEROUPPER、非对齐存储、复杂操作）
  → 修复：对齐数据、使用直接 AVX2/512 加载/存储路径

Retiring 较低（< 50%）？
  → 系统性低效；上报性能专项团队
```

### 9.4 采集示例

```bash
# 单线程程序，时间序列
AMDuProfPcm -m pipeline_util -c core=1 \
    -o /tmp/td.csv -- /usr/bin/taskset -c 1 /tmp/myapp

# 多线程，累积系统聚合
AMDuProfPcm -m pipeline_util -a -A system \
    -C -o /tmp/td.csv -- /tmp/myapp
```

---

## 10. Roofline 建模与算术强度分析

### 10.1 理论基础

经典 Roofline 模型在双对数坐标系中映射应用性能：

```
Y 轴：性能（GFLOPS/sec）
X 轴：算术强度 AI（FLOPS/Byte）

可达性能 = min(峰值 GFLOPS/sec, 峰值内存带宽 × AI)

屋顶线：
  水平线：计算上限（FP 峰值，与 AI 无关）
  斜线：  内存带宽上限（斜率 = 峰值 BW，GB/s）
  脊点：  计算上限与内存上限的交点
```

应用操作点位于脊点左侧表示**内存瓶颈**，右侧表示**计算瓶颈**。

```
GFLOPS/s
  │(log)
  │
  │                                  ● C（计算瓶颈）
峰│- - - - - - - - - - -●脊点────────────────── 计算上限（FP Peak）
值│               ↗     │
  │          ↗ /        │
  │      ↗ /            │
  │  ↗ /  ← BW × AI    │
  │↗/                   │
  │/ ● A（内存瓶颈）      │ ● B（接近脊点）
  └──────────────────────┼──────────────────────→ AI (FLOPS/Byte, log)
  低 AI                脊点 AI               高 AI
  （内存受限区）                          （计算受限区）

  斜线斜率 = 峰值内存带宽（GB/s）
  脊点 AI  = 峰值 GFLOPS ÷ 峰值带宽（GB/s）
             （EPYC 9645 示例：~3.6 TFLOPS FP64 ÷ 460 GB/s ≈ 7.8 FLOPS/Byte）

  A：AI 低，远低于带宽线 → 优化数据局部性、提高缓存复用
  B：AI 接近脊点，已接近最优 → 可尝试混合精度或向量化
  C：AI 高，受限于计算峰值 → 优化指令级并行、FMA 利用率
```

AMDuProfPcm 自动采集：
- 浮点运算次数（Core PMC `fp` 事件）
- DRAM 流量（DF PMC `memory` 事件）
- 执行时间 → 计算 GFLOPS/sec 和 AI

### 10.2 采集工作流

**第一步 —— 采集并生成 HTML Roofline 报告：**
```bash
AMDuProfPcm roofline -O /tmp/roofline -- /tmp/myapp.exe
# 输出：/tmp/AMDuProfPcm-Roofline-<date>-<time>/report.html
```

**备注 —— `--msr` 回退模式：**

在现代内核（≥ 6.2）和标准发行版上，AMDuProfPcm 默认通过 Linux Perf 驱动采集 DF 内存计数器，无需额外参数（输出头部可见 `Data Collection Driver: Linux Perf Driver`）。

`--msr` 仅在以下情况下需要：内核较旧（< 6.2）或内核配置裁剪导致缺少 `amd_df` Uncore PMU 驱动支持时，工具会自动回退到直接读取 MSR 寄存器：
```bash
# 仅在 Perf 模式无法采集 DF 计数器时使用（老内核 / 非标准内核配置）
AMDuProfPcm roofline --msr -O /tmp/roofline -- /tmp/myapp.exe
```

### 10.3 使用基准测试峰值的实测 Roofline

用实测峰值替换理论峰值以提高真实性：

```bash
# 使用 STREAM 基准测试分数作为内存上限
AMDuProfModelling.py -i roofline.csv -o /tmp/ \
    --stream <STREAM_triad_GB_per_s> -a myapp

# 使用 HPL/GEMM 分数作为计算上限
AMDuProfModelling.py -i roofline.csv -o /tmp/ \
    --hpl <HPL_GFLOPS> --gemm <DGEMM_GFLOPS> -a myapp
```

建议**每季度校准**一次（重跑 STREAM/HPL），随硬件配置变化刷新 Roofline 上限和告警阈值。

### 10.4 Roofline 解读与 CI 集成

```
操作点位于脊点左侧且在斜线以下 → 内存瓶颈
  → 检查 Data Cache Fill/局部性（第 8 节），查看 xGMI（第 9.2 节）

操作点位于脊点右侧且在计算上限以下 → 后端 CPU 瓶颈
  → 检查向量化利用率（-m avx_imix）、FMA 速率（-m fp）
```

**CI 门控示例：**
```bash
AMDuProfPcm roofline -O /tmp/roofline -- ./benchmark
python3 tools/roofline_guard.py \
    --csv /tmp/roofline/*/roofline.csv \
    --min-ai 0.7 \
    --min-gflops 150
# 若 AI 下降 > 15% 或 GFLOPS 下降 > 20% 则构建失败
```

**过滤启动/收尾噪声：**
```bash
AMDuProfPcm roofline -f util:90 -O /tmp -- ./myapp
```

**一体化采集（时间序列 + 累积 + Roofline 单次运行）：**
```bash
AMDuProfPcm profile \
    --report-roofline --collect-power --collect-xgmi \
    -a -A system,package \
    -d 120 -O /tmp/fullprofile
```

---

## 11. 虚拟化与容器约束

### 11.1 虚拟机内的 PMC 可用性

运行 `AMDuProfCLI info --system` 并检查 `PERF Features Availability` 和 `Hypervisor Info` 字段。

| PMC 类型 | 裸金属 | 虚拟机（典型） |
|---------|-------|-------------|
| Core PMC | 完整 | 部分（取决于虚拟机监控程序） |
| L3 PMC | 完整 | 通常受限 |
| DF PMC | 完整 | **不可用**（安全隔离） |

**从宿主机隔离 VM 工作负载分析：**
```bash
# 仅计数 Guest 事件
AMDuProfPcm -m ipc,l3,memory -a --collect-guest -d 60 -O /tmp/guest-profile

# 默认：Host + Guest 合并
AMDuProfPcm -m memory -a -d 60 -O /tmp/all

# 仅计数 Host 事件（排除 VM 开销）
AMDuProfPcm -m ipc -a --collect-host -d 60 -O /tmp/host-only
```

### 11.2 容器支持

```bash
# 在容器内运行
docker run --cap-add=CAP_SYS_ADMIN \
    -v /tmp/output:/output \
    my-uprof-image \
    AMDuProfPcm -m ipc,l3 -a -d 60 -O /output

# 从宿主机附加到容器化进程
AMDuProfPcm -m ipc -p <container_pid> -d 60 -O /tmp/container-profile
```

---

## 12. 高级诊断工作流

### 12.1 推荐分诊顺序

```
第一步 —— AMDuProfPcm 全系统（始终首先运行）
   ├─ UMC 带宽高（> 峰值 60%）？  → 内存带宽瓶颈 → §12.4，案例 §17.5
   ├─ L3 CCX Miss PTI 高？         → CCX 亲和性问题 → §8，案例 §17.2
   ├─ xGMI 利用率高？              → 跨 socket 流量 → NUMA 问题 → 案例 §17.1
   └─ 带宽正常，IPC 低？           → 计算或分支 → 第二步

第二步 —— EBP assess / assess_ext（逐进程）
   ├─ IPC 低 + %DC Miss 高？       → cache miss链 → 案例 §17.5
   ├─ %Branch Mispredicted 高？    → 分支模式 → 案例 §17.6
   ├─ Mixed SSE/AVX Stalls 高？    → AVX 切换 → 案例 §17.3
   └─ IPC 低，%DC Miss 低？        → 可能是false sharing → 案例 §17.4

第三步 —— IBS（定位到具体指令）
   ├─ 哪条加载指令延迟最高？
   ├─ VA 模式是顺序还是随机？→ 延迟瓶颈 vs 带宽瓶颈的判断
   └─ 哪条指令触发 SSE/AVX 切换？

第四步 —— Power 分析器（有效频率偏低时）
   └─ Socket 功耗达到 TDP？→ 频率受限 → 案例 §17.7
```

### 12.2 NUMA 不均衡诊断

```bash
# 第一步：检查每 socket DRAM 利用率不对称性
AMDuProfPcm -m memory -a -A system,package -d 60 -C -O /tmp/step1

# 第二步：通过 Data Cache Fill 确认跨 socket 数据访问
AMDuProfPcm -m dc -a -A system,package -d 60 -C -O /tmp/step2
# Remote DRAM Read % > 10% 确认问题存在

# 第三步：确认 xGMI 链路利用率不对称
AMDuProfPcm -m xgmi --collect-xgmi -a -A package -d 60 -O /tmp/step3

# 第四步：绑定后重新分析以衡量改善效果
numactl --cpunodebind=0 --membind=0 ./myapp &
AMDuProfPcm -m memory,dc,xgmi -c package=0 -A system -d 60 -C -O /tmp/step4
```

### 12.3 缓存压力分析

```bash
# L1/L2/L3 级联缺失分析
AMDuProfPcm -m l1,l2,l3 -a -A ccx -d 60 -C -O /tmp/cache
# L2 Miss from DC Miss >> L2 Miss from IC Miss → 数据工作集超出 L1
# L3 Miss % > 20% → 工作集超出 L3；检查内存带宽充裕度
# Ave L3 Miss Latency > 200 周期 → 可能是远端 DRAM 服务 L3 miss

# prefetch effectiveness
AMDuProfPcm -m hwpfdc,swpfdc -a -A system -d 60 -C -O /tmp/prefetch
```

### 12.4 延迟瓶颈与带宽瓶颈的区分

两种情况在 EBP 中都表现为高 `%DC Miss`，但优化策略截然不同。

| 指标 | 延迟瓶颈 | 带宽瓶颈 |
|-----|---------|---------|
| `UMC Read BW`（PCM） | 低至中等（< 峰值 50%） | 高（> 峰值 70%） |
| `IPC` | 极低（< 1.0） | 中等（1.0–2.0） |
| IBS 加载延迟 | 极高（300–500+ 周期） | 中等（150–250 周期） |
| 线程数扩展 | **不**改善吞吐量 | 线性改善直至达到带宽峰值 |

**延迟瓶颈示例：** 图遍历、指针追踪、哈希表查找 —— 串行内存请求（下一地址未知直到上一个返回）。

**带宽瓶颈示例：** STREAM 型循环、稠密矩阵运算 —— 大量并发未完成请求。

```bash
# 同时运行两者进行关联分析
AMDuProfPcm -m memory -a -d 60 -o /tmp/pcm.csv &
AMDuProfCLI collect --config ibs -p <PID> -d 60 -o /tmp/ibs
# 将 PCM 的 UMC 带宽与 IBS 加载延迟直方图交叉对比
```

**延迟瓶颈修复：** software prefetch（`_mm_prefetch`）、AoS→SoA 重构、缩小工作集、NPS=1 降低跨 NUMA 延迟。

**带宽瓶颈修复：** 缓存分块/分片、降低数据精度（FP64→FP32→BF16）、NPS=4 最大化聚合带宽。

### 12.5 AVX/FP 吞吐量排查

```bash
AMDuProfPcm -m fp,avx_imix -a -A system -d 60 -C -O /tmp/fp-check
# 红色警报：
#   Mixed SSE/AVX Stalls (pti) > 0     → 模式切换惩罚
#   Scalar FP Ops Retired (%) > 50%    → 错失向量化机会
#   Packed 128-bit Ops 占主导           → AVX2/AVX-512 未被利用

# 交叉对比 pipeline_util
AMDuProfPcm -m pipeline_util -a -A system -C -O /tmp/pipeline -- ./myapp
```

### 12.6 逐进程监控（Perf 模式）

```bash
./myapp &
APP_PID=$!
AMDuProfPcm -m ipc,l2,l3,dc \
    -a -A system \
    -p $APP_PID \
    -I 500 \
    -o /tmp/app-timeseries.csv
# 仅在 myapp 线程被调度的 core 上计数硬件事件
```

---

## 13. 生产监控：告警、仪表盘与集成

### 13.1 告警阈值

| 信号 | 警告 | 严重 | 备注 |
|-----|------|------|------|
| IPC（系统聚合） | 持续 60 秒 < 1.8 | 持续 30 秒 < 1.2 | 结合 Frontend/Backend 占比以分类根因 |
| Remote DRAM Read % | > 6% | > 10% | 自动触发 NUMA 重均衡操作手册 |
| UMC 总带宽 | > STREAM 基线 80% | > STREAM 基线 90% | 按 SKU 对比 STREAM；不是固定 GB/s 数值 |
| `Backend_Bound.Memory` | > 35% | > 50% | 仅 Zen 4+；基于 pipeline_util 指标告警 |
| `Retiring` 占比 | < 55% | < 40% | 系统性低效；上报性能专项团队 |
| xGMI 链路不对称 | 链路间差异 > 30% | 链路间差异 > 50% | Socket 间数据不均衡 |
| Ave L3 Miss Latency | > 150 周期 | > 250 周期 | 表明远端 DRAM 正在服务 L3 miss |
| Mixed SSE/AVX Stalls（pti） | > 5 | > 20 | 运行时/库将 SSE 注入 AVX 代码 |

在仪表盘中将指标对齐到相同时间轴（Core、L3、pipeline、内存），便于追溯因果关系。

### 13.2 CSV → 指标pipeline

```bash
# 持续采集，写入日志目录
AMDuProfPcm -m l3,memory \
    -a -A system,package,ccx \
    -I 1000 -d 0 \
    -o /var/log/uprof/$(hostname)-fabric.csv
```

将 CSV 输入流式解析器 → Prometheus 导出器：
```
uprof_umc_read_gbs{host="epyc01", channel="A"}
uprof_l3_miss_pct{host="epyc01", ccx="0"}
uprof_remote_dram_pct{host="epyc01", socket="0"}
```

所有指标都应打标签：`host`、`sku`（EPYC 型号）、`bios_version`、`kernel_version` —— 这对多代际机群回归分类至关重要。

### 13.3 机群能力矩阵

部署前为每个节点建立可用指标清单：

```bash
# 在每个目标节点上执行
AMDuProfCLI info --system | grep -E "(Family|Model|Virtualization|Features)"
```

在自动化标签（Ansible 主机变量、Prometheus 目标标签）中记录每个节点有效的指标标志，避免采集器在不支持的代际上失败。`pipeline_util` 不可用的节点（Zen 2/3）必须使用不同的告警规则。

### 13.4 事件集成

将 AMDuProf 快照集成到事件回顾复盘中：
- 告警触发时：自动以 100 ms 多路复用间隔抓取 2 分钟高保真 CSV 作为证据。
- 与事件时间线一同存档，用于事后分析。
- 建立可搜索的知识库：计数器特征签名 → 根因模式映射。

```bash
# 高保真事件快照（2 分钟，细粒度多路复用）
AMDuProfPcm -m ipc,l3,memory,dc,pipeline_util \
    -a -A system,package \
    -t 50 -I 200 \
    -d 120 \
    -o /var/log/uprof/incident-$(date +%Y%m%d_%H%M%S).csv
```

---

## 14. 自定义配置文件与原始 PMC 事件监控

### 14.1 配置文件结构

预置配置文件路径：
- Linux：`/opt/AMDuProf_X.Y-ZZZ/bin/Data/Config/`
- Windows：`<uprof-install-dir>\bin\Data\Config\`

命名规则：`<Family>_<ModelRange>.conf` —— 例如 `0x19_0x1.conf` 覆盖 EPYC Zen 3（family 0x19，型号 0x10–0x1F）。Roofline 配置以 `RL_` 为前缀。

### 14.2 自定义事件监控

```bash
# -i 与 -m 互斥
AMDuProfPcm -i /path/to/custom.conf -a -d 60 -O /tmp/custom-out
```

复制并修改原版配置文件，定义自定义事件集和计算指标。文件中所有事件都将被采集和报告。

### 14.3 原始 PMC 事件发现

```bash
# 列出所有支持的原始 Core PMC 事件
AMDuProfPcm -l

# 查看特定事件的描述和单元掩码
AMDuProfPcm -z PMCx0C0    # retired instructions
AMDuProfPcm -z PMCx076    # 非stall CPU 时钟
AMDuProfPcm -z PMCx03     # LS dispatch
```

### 14.4 内核/用户模式过滤

> **实测注意（v5.1.756，Zen 5）：`-u` 参数在当前版本不可用，执行时报 `Invalid option -u`。** 如需区分内核/用户态开销，可使用 `-m ipc` 中的 `System Time (%)` / `User Time (%)` / `IPC (Sys)` / `IPC (User)` 指标替代。

### 14.5 进程与线程定向

```bash
# 定向到特定进程（仅 Perf 模式，Linux）
AMDuProfPcm -m ipc -p <PID> -a -A system -d 60 -o /tmp/proc.csv

# 定向到特定线程
AMDuProfPcm -m ipc --tid <tid1,tid2> -a -A system -d 60 -o /tmp/thr.csv
```

---

## 15. 输出格式与后处理

### 15.1 CSV（默认）

每行为时间序列数据，列标题包含每个指标和聚合级别。适用于：
- pandas/numpy 自定义分析
- Excel 数据透视表
- Grafana/InfluxDB/Prometheus pipeline

```bash
AMDuProfPcm -m ipc -a -s -d 60 -o /tmp/timed.csv    # 添加时间戳
AMDuProfPcm -m memory -a -P 4 -d 60 -o /tmp/out.csv # 4 位小数精度
AMDuProfPcm -n                                        # 打印拓扑结构
```

### 15.2 HTML 报告（`--html`）

生成的报告包含：
- 各指标组的时间序列图
- 热图（时间维度的 core 利用率矩阵）
- 旭日图（层次化指标细分）
- 雷达图（指标特征签名）
- Roofline 图（如采集了 Roofline 数据）

JSON 中间结构：
```
├── hierarchy   → 拓扑：system > package > ccd > ccx > core
├── metadata    → 系统信息、CPU 型号、内核、采集参数
├── metric-groups → 相关指标的逻辑分组
├── metrics     → 每个时间样本的实际采集值
└── sections    → 渲染图表的配置
```

### 15.3 后处理模板

```bash
# 将已有 CSV 事后转换为 HTML
AMDuProfPcm hreport <output-dir>

# 在输出中隐藏 CPU 拓扑部分（用于脚本化）
AMDuProfPcm -m ipc -a -q -d 60 -o /tmp/compact.csv

# 在 package 级别计数器前添加 "pkg" 标签
AMDuProfPcm -m memory -a -k -d 60 -o /tmp/labeled.csv
```

---

## 16. 已知限制与 BIOS 交互

### 16.1 BIOS prefetcher设置与 L2 HWPF 指标

| L1 Stream | L1 Stride | L1 Region | L2 Stream | L2 Up/Down | HWPF 指标结果 |
|:---------:|:---------:|:---------:|:---------:|:----------:|:------------|
| 关 | 关 | 关 | 关 | 关 | **无数据** |
| 关 | 关 | 开 | 关 | 关 | 极少量样本 |
| 任一开 | — | — | — | — | 正常工作 |

在所有prefetcher 均关闭的严格服务器 BIOS（金融 HPC 中为确保确定性延迟常见此配置）上，`hwpfdc` 和 L2 HWPF 指标将为空。改用 `swpfdc` 分析并添加显式software prefetch。

### 16.2 MSR 模式约束

- 最小采样间隔：1000 ms —— 无法实现亚秒级粒度。
- 极低 L3 访问次数时 L3 Miss % > 100%：视为噪声丢弃。
- 多个并发 MSR 模式实例使用 `-r` → 未定义行为。
- 异构 core 配置（同一系统中混合 Zen 3 + Zen 4）可能导致未定义行为。

### 16.3 测量精度

- 不支持低于 1 秒（1000 ms）的采样间隔。
- MSR 模式开销较大；样本数可能不等于 `持续时间 / 间隔`。
- 分析运行期间关闭 core 会导致未定义行为。
- 云虚拟机监控程序可能屏蔽某些 Guest PMC 事件，导致这些计数器报告为 0。

### 16.4 Roofline 图表标签

通过 `AMDuProfModelling.py` 生成的 PDF Roofline 图在某些 matplotlib 版本中可能出现坐标轴标签错位。以 `--html` 作为主要可视化路径。

### 16.5 Zen 1 / Zen 2 限制

- Zen 2 不支持 HTML 报告。
- Zen 2 不支持虚拟化指标。
- 与 Zen 3+ 相比指标覆盖有限。
- Zen 1/2 建议使用 MSR 模式访问 L3 和 DF PMC。

---

## 17. 真实案例研究

### 17.1 数据库工作负载中的 NUMA 非感知内存分配

**平台：** 2-socket EPYC 9654，NPS=4（共 8 个 NUMA 节点），MySQL InnoDB。
**症状：** 查询延迟比对标 Intel 2P 基准高 40%。

**第一步 —— 使用 AMDuProfPcm 进行系统级分析：**
```bash
AMDuProfPcm -m ipc,l3,memory -a -A system,package -d 60 -o /tmp/pcm.csv
```
结果：IPC = 1.1（数据库工作负载偏低），`L3 CCX Miss PTI` = 45（极高），`UmcRdBw` = 280 GB/s（高但未达峰值 → 延迟瓶颈，而非带宽瓶颈）。

**第二步 —— EBP data_access 分析：**
```bash
AMDuProfCLI collect --config data_access -p $(pgrep mysqld) -d 30 -o /tmp/mysql-dc
AMDuProfCLI report -i /tmp/mysql-dc.caperf --view dc_access
```
结果：`DC Refills From Remote DRAM PTI` = 38（共 45 次 L3 miss中的 38 次）→ **85% 的 DRAM 获取来自远端 NUMA 节点**。

**根因：** MySQL 线程池在 socket 0 上创建，但 InnoDB 缓冲池内存通过默认 `malloc` 跨所有 NUMA 节点随机分配。socket 0 上的线程持续从 socket 1 的 DRAM 获取缓冲池页面。

**修复：**
```bash
numactl --cpunodebind=0,1,2,3 --membind=0,1,2,3 mysqld
# 或在 MySQL 配置中：innodb_numa_interleave = 0
```

**结果：** `DC Refills From Remote DRAM PTI` 从 38 降至 4。IPC 从 1.1 提升至 2.3。查询延迟下降 35%。

**AMDuProfPcm 特征：** `Remote DRAM Read %` 是 NUMA 不均衡最快速的单一指示器。

---

### 17.2 多线程 HPC 中的 CCX L3 抖动

**平台：** EPYC 9654（96 核，12 个 CCX），OpenFOAM CFD 求解器。
**症状：** 超过 32 线程后扩展性崩溃；96 线程比 64 线程更慢。

**第一步 —— L3 分析：**
```bash
AMDuProfPcm -m l3 -a -A system,ccx -d 60 -o /tmp/l3.csv
```
`L3 CCX Miss PTI` 从 32 线程时的 8 跳至 96 线程时的 52 —— 跨 CCX 流量增加 6 倍。

**第二步 —— 使用 IBS 定位问题数据结构：**
```bash
AMDuProfCLI collect --config ibs -d 30 -o /tmp/foam-ibs ./foamRun -case cavity
```
IBS 识别出全部 96 个线程跨 12 个 CCX 对**全局面主数组**的加载 —— 网格分解未考虑 CCX 边界。

**根因：** OpenFOAM 的 `scotch` 分解器在分配面时不考虑 CCX 拓扑结构。共享的面主数组和面邻数组被所有线程以高跨 CCX 访问频率读取。

**修复：**
```bash
# 使用与 CCX 边界对齐的层次化分解（每 CCX 8 线程）
# decomposeParDict: method hierarchical; n (1 1 12)

# 或将线程组绑定到 CCX：
OMP_NUM_THREADS=96 OMP_PROC_BIND=close OMP_PLACES=cores ./foamRun
```

**结果：** 96 线程时 `L3 CCX Miss PTI` 从 52 降至 11。扩展效率从 51% 提升至 83%。

---

### 17.3 ML 推理中的混合 SSE/AVX 切换stall

**平台：** EPYC 9654，TensorFlow 推理（MKL-DNN core + GCC OpenMP 运行时）。
**症状：** 尽管 IPC（2.8）良好且cache miss率低，吞吐量仍比理论峰值低 30%。

**第一步 —— EBP assess 分析：**
```bash
AMDuProfCLI collect --config assess_ext -p $(pgrep python) -d 30 -o /tmp/tf-assess
```
`Mixed SSE/AVX Stalls PTI` = 120（干净 AVX 代码预期 < 5）。

**第二步 —— IBS 定位切换点：**
IBS 发现切换发生在 `libgomp.so` 和 `libpthread.so` 内部，而非 TF core 中。OpenMP 运行时在 AVX-512 并行区段之间使用了旧版 SSE `movaps` 指令。每次切换产生 ~70 周期惩罚（`VZEROUPPER` 未被正确调用）。

**修复：**
```bash
export TF_ENABLE_ONEDNN_OPTS=1
export ONEDNN_MAX_CPU_ISA=AVX512_CORE_AMX
# 或使用 AMD AOCL（全程 AVX 干净）
```

**结果：** `Mixed SSE/AVX Stalls PTI` 从 120 降至 3。推理吞吐量提升 28%。

---

### 17.4 高并发服务中的false sharing

**平台：** EPYC 9654（96 核），Go gRPC 服务，128 个 goroutine。
**症状：** CPU 利用率 95%，但吞吐量停滞在单线程外推的 60%。

**第一步 —— EBP assess：** IPC = 0.6（极低），`%DC Miss` = 18%（高）。

**第二步 —— IBS 加载延迟分析：**
```bash
AMDuProfCLI collect --config ibs -d 30 -o /tmp/grpc-ibs ./grpc-server
```
对共享 `stats` 结构体地址的加载显示平均加载延迟 **280 周期** —— 接近 DRAM 延迟 —— 尽管数据在本地内存中。这是false sharing的典型特征：L1 命中但cache line被远端 core 持续失效。

**根因：** `stats` 结构体字段（Requests、Errors、Latency）打包在同一个 64 字节cache line中。128 个 goroutine 同时递增不同字段 → 持续cache line invalidation。

**修复：**
```go
// 修复后：cache line padding
type Stats struct {
    Requests int64
    _        [56]byte
    Errors   int64
    _        [56]byte
    Latency  int64
    _        [56]byte
}
```

**结果：** `%DC Miss` 从 18% 降至 2%。IPC 从 0.6 提升至 2.9。吞吐量达到理论值的 94%。

**AMDuProfPcm 特征：** DRAM 填充 PTI 低 + `%DC Miss` 高 + IBS 加载延迟极高 → 数据在本地但 L1 缺失（cache line被远端 core 失效）。

---

### 17.5 内存延迟瓶颈与带宽瓶颈的区分

**场景：** 两个工作负载在 EBP 中均显示高 `%DC Miss`。

参见 §12.4 诊断表。core 工作流：

```bash
# 同时运行两者
AMDuProfPcm -m memory -a -d 60 -o /tmp/pcm.csv &
AMDuProfCLI collect --config ibs -p <PID> -d 60 -o /tmp/ibs
# 将 PCM 的 UMC 带宽与 IBS 加载延迟直方图交叉对比
```

若 IBS 平均加载延迟 > 300 周期 **且** UMC 带宽 < 峰值 50% → **延迟瓶颈**：software prefetch、AoS→SoA、缩小工作集。

若 IBS 延迟 150–250 周期 **且** UMC 带宽 > 峰值 70% → **带宽瓶颈**：缓存分块、降低数据精度、跨 NUMA 分散线程。

---

### 17.6 哈希查找中的branch misprediction

**平台：** EPYC 9654，类 Redis 键值存储。
**症状：** 同一二进制文件在 Intel 上吞吐量高 40%；综合基准 IPC 相同。

**第一步 —— EBP 分支分析：**
```bash
AMDuProfCLI collect --config branch -p $(pgrep kvserver) -d 30 -o /tmp/kv-branch
AMDuProfCLI report -i /tmp/kv-branch.caperf --view br_assess
```
`%Retired Branch Instructions Mispredicted` = EPYC 上 8.2% vs Intel 上 3.1%。

**根因：** 哈希函数存在细微字节序假设，导致在 EPYC 上分布不均匀 → 更多哈希碰撞 → 探测循环中更多数据依赖分支 → branch predictor无法学习该模式。Zen 4 的间接branch predictor使用与 Intel 不同的历史长度。

**修复：**
1. 用 `XXH3` 或 `wyhash` 替换哈希函数（在所有 x86 上均匀分布）。
2. 将线性探测碰撞循环替换为无分支 SIMD 比较：

```c
// 修复后：SIMD 8 路比较（无分支）
__m256i keys8 = _mm256_set1_epi32(key);
__m256i slots = _mm256_loadu_si256((__m256i*)&table[idx]);
int match = _mm256_movemask_epi8(_mm256_cmpeq_epi32(slots, keys8));
```

**结果：** `%Branch Mispredicted` 从 8.2% 降至 0.9%。吞吐量比 Intel 高出 12%（EPYC 更高内存带宽使 SIMD 探测受益）。

---

### 17.7 AVX-512 重载下的 Boost 频率崩溃

**平台：** EPYC 9684X（96 核，3D V-Cache），VASP DFT 模拟。
**症状：** `lscpu` 显示最大 Boost 3.7 GHz；分析工具显示有效频率 2.9 GHz。

**第一步 —— Power 分析器：**
```bash
AMDuProfCLI timechart \
    --device socket=0 \
    --counter power,frequency,temperature \
    -d 60 -o /tmp/vasp-power.csv
```
结果：`Socket Package Power` = 402 W（额定 TDP = 400 W），温度 = 88°C。

**根因：** VASP 对全部 96 个 core 同时运行 AVX-512 FMA。封装功耗超过 TDP，固件降低所有 core 的 Boost 频率以维持功耗预算。这是正确行为，但意味着 96 核全 AVX-512 满载时有效频率为 2.9 GHz，而非 3.7 GHz。

**优化选项：**

| 方案 | 权衡 |
|-----|------|
| 将 `OMP_NUM_THREADS` 降至 64–72 | 减少节流 → 更高单核频率 → 整体有时更快 |
| BIOS 中提高 TDP（若散热允许） | 更多余量 → 更高持续频率 |
| `amd-pstate` 性能调速器 + 更高功耗上限 | 最大化持续性能 |
| 利用 3D V-Cache：缩减工作集以适入 1152 MB L3 | 减少内存stall → 更高有效吞吐量 |

```bash
# 查看当前功耗上限（只读，安全）
cat /sys/class/powercap/amd-rapl/*/constraint_0_power_limit_uw
```

> ⚠️ **写入 RAPL 功耗限制有较高风险，生产环境慎用。** 修改 RAPL 限制会绕过 CPU TDP 保护机制。若设定值超过散热设计上限，可能引发持续高温、芯片寿命缩短或热失控；应通过 BIOS/BMC 调整 TDP 设置，并在散热条件确认充分后进行。以下命令仅供参考：
> ```bash
> # 示例：写入 500W 限制（单位：微瓦）—— 请替换为实际允许的值
> echo 500000000 > /sys/class/powercap/amd-rapl/0/constraint_0_power_limit_uw
> ```

**结果：** `OMP_NUM_THREADS=72` 将有效频率提升至 3.3 GHz。VASP 运行时改善 11%（尽管线程数更少）。

---

## 18. 附录：按 Zen 代际划分的指标快速参考

### 指标组 → 标志映射

| 指标组 | 标志 | Zen 2 | Zen 3 | Zen 4 | Zen 5 |
|-------|------|:-----:|:-----:|:-----:|:-----:|
| IPC / CPI / 频率 | `-m ipc` | ✓ | ✓ | ✓+ | ✓+ |
| 浮点 | `-m fp` | ✓ | ✓ | ✓ | ✓ |
| L1 缓存 | `-m l1` | ✓ | ✓ | ✓ | ✓ |
| L2 缓存 | `-m l2` | ✓ | ✓ | ✓ | ✓ |
| TLB | `-m tlb` | ✓ | ✓ | ✓ | ✓ |
| L3 缓存 | `-m l3` | ✓ | ✓ | ✓+ | ✓+ |
| 按来源的 Data Cache Fill | `-m dc` | — | ✓ | ✓+ | ✓+ |
| software prefetch DC | `-m swpfdc` | — | ✓ | ✓ | ✓ |
| hardware prefetch DC | `-m hwpfdc` | — | ✓ | ✓ | ✓ |
| cache miss汇总 | `-m cache_miss` | ✓ | ✓ | ✓ | ✓ |
| AVX 指令混合 | `-m avx_imix` | — | — | ✓ | ✓ |
| 自顶向下pipeline | `-m pipeline_util` | — | — | ✓ | ✓ |
| 内存带宽 | `-m memory` | ✓ | ✓ | ✓+ | ✓+ |
| xGMI 带宽 | `-m xgmi` | ✓ | ✓ | ✓ | ✓ |
| PCIe 带宽 | `-m pcie` | ✓ | — | ✓ | ✓ |
| DMA 带宽 | `-m dma` | — | — | ✓ | ✓ |
| CCM 带宽 | `-m ccm_bw` | — | — | ✓ | ✓ |
| CXL 带宽 | `-m cxl` | — | — | — | ✓ |
| UMC 指标 | （memory 的一部分） | — | — | — | ✓ |
| Roofline | `roofline` | ✓ | ✓ | ✓ | ✓ |

✓+ = 相比上一代提供扩展指标。

### 症状 → 指标查询

| 症状 | 首要指标 | 深入排查 |
|-----|---------|---------|
| IPC 低、CPI 高 | `-m ipc`、`-m pipeline_util` | Frontend_Bound 或 Backend_Bound 子桶 |
| 内存带宽饱和 | `-m memory`、`-m ccm_bw` | 通过 `-A package` 查看每通道 |
| 缓存抖动 | `-m l2`、`-m l3`、`-m dc` | Data Cache Fill 来源分布 |
| NUMA 低效 | `-m dc`（Remote DRAM Read %）、`-m xgmi` | 通过 `-A package` 查看每 socket |
| prefetch覆盖不足 | `-m hwpfdc`、`-m swpfdc` | 对比需求与prefetch的来源混合 |
| AVX 利用率低 | `-m avx_imix`、`-m fp` | 标量占比和混合stall |
| frontend bottleneck | `-m pipeline_util`、`-m l1`、`-m tlb` | Latency vs BW 子桶 |
| branch misprediction | `-m ipc`（Branch Mis-predict Ratio） | EBP `branch` 配置获取逐函数细节 |
| PCIe/DMA I/O 瓶颈 | `-m pcie`、`-m dma` | 通过 `-A package` 查看每 quad |
| 多 socket 不均衡 | `-m xgmi`、`-m memory` | 链路不对称 + 每 socket 带宽 |
| false sharing | IBS 加载延迟 | 高延迟 + 低 DRAM 填充 |
| 功耗/频率节流 | Power 分析器 | Socket 封装功耗 vs TDP |
| CXL 内存分层 | `-m cxl`、`-m memory` | CXL vs DRAM 带宽比（Zen 5） |

### CLI 快速参考

```bash
# ── 前提条件 ───────────────────────────────────────────────────
# ⚠️ 以下命令会临时修改系统安全/稳定性设置，采集结束后须恢复原值
# perf_event_paranoid=0 允许非 root 访问 PMC，存在信息泄露风险
echo 0 > /proc/sys/kernel/perf_event_paranoid   # 恢复：echo 1 > ...
# nmi_watchdog=0 禁用 hard lockup 检测，内核死锁将不自动恢复
echo 0 > /proc/sys/kernel/nmi_watchdog          # 恢复：echo 1 > ...
sudo modprobe msr
sudo /opt/AMDuProf_<version>/bin/AMDPcmSetCapability.sh  # 非 root MSR 模式（推荐替代 paranoid=0）
cpupower frequency-set -g performance  # ⚠️ 仅基准对比时使用，生产监控不需要
ulimit -n $(($(nproc) * 100))          # 仅影响当前 shell 会话

# ── 全系统 ─────────────────────────────────────────────────────
AMDuProfPcm -m ipc -a -d 60 -o /tmp/ipc.csv
AMDuProfPcm -m l3 -a -d 60 -o /tmp/l3.csv
AMDuProfPcm -m memory -a -d 60 -o /tmp/bw.csv
AMDuProfPcm -m ipc,l3,memory -a -A system,package -d 60 --html -O /tmp/all
AMDuProfPcm -m ipc,l3 -c ccx=0 -d 60 -o /tmp/ccx0.csv

# ── 性能分析器 ─────────────────────────────────────────────────
AMDuProfCLI collect --config tbp -d 30 -o /tmp/out ./app
AMDuProfCLI collect --config assess -d 30 -o /tmp/out -p <PID>
AMDuProfCLI collect --config data_access -d 30 -o /tmp/out -p <PID>
AMDuProfCLI collect --config branch -d 30 -o /tmp/out -p <PID>
AMDuProfCLI collect --config ibs -d 30 -o /tmp/out -p <PID>
AMDuProfCLI report -i /tmp/out.caperf --view triage_assess --src-path /src/
AMDuProfCLI report -i /tmp/out.caperf --view dc_access
AMDuProfCLI report -i /tmp/out.caperf --view br_assess

# ── 功耗 / 温度 ─────────────────────────────────────────────────
AMDuProfCLI timechart --device socket=0 \
    --counter power,temperature,frequency -d 60 -o /tmp/power.csv

# ── 拓扑 ───────────────────────────────────────────────────────
AMDuProfPcm -n                         # 显示 socket > CCD > CCX > core 映射
AMDuProfCLI info --system              # 完整系统能力信息
AMDuProfCLI info --list collect-configs
AMDuProfCLI info --list view-configs
```

---

## 19. EPYC 9645 实机输出速查（AMDuProfPcm v5.1.756）

> **环境：** AMD EPYC 9645 96-Core × 2 Socket，384 线程，Ubuntu 22.04，Linux 6.8.0，AMDuProfPcm v5.1.756（内部版本），Perf 模式，空载基线。所有命令均在实机执行并截取关键输出行。

---

### 19.1 前置条件验证

> ⚠️ 以下两条命令会临时降低系统安全性和可靠性，采集完成后应立即恢复。详见第 3.1 节的风险说明。

```bash
# 临时允许非 root 访问 DF PMC（重启后自动恢复）
echo 0 > /proc/sys/kernel/perf_event_paranoid
# 临时禁用 hard lockup 检测（重启后自动恢复）
echo 0 > /proc/sys/kernel/nmi_watchdog

# 验证当前值
cat /proc/sys/kernel/perf_event_paranoid   # → 0
cat /proc/sys/kernel/nmi_watchdog          # → 0

# 采集完成后恢复（不重启的情况下）：
# echo 1 > /proc/sys/kernel/perf_event_paranoid
# echo 1 > /proc/sys/kernel/nmi_watchdog
```

---

### 19.2 系统拓扑（`-n`）

```bash
AMDuProfPcm -n
```

```
-------------------------------------
 Package Numa    CCX    Core    Thread
-------------------------------------
 0         0       0     0      0
 0         0       0     0      192
 0         0       0     1      1
 0         0       0     1      193
 ...
 0         0       1     12     72
 0         0       1     12     264
 ...
 1         8       ...（第二 Socket，CCX 8–15）
```

> Zen 5（9645）：2 Socket × 8 CCX × 12 Core × 2 Thread = 384 线程。每个 CCX 包含 12 个物理 core 和 24 个逻辑 thread。

---

### 19.3 系统能力信息（`AMDuProfCLI info --system`）

```bash
AMDuProfCLI info --system
```

```
[OS Info]
    OS Details              : Linux Ubuntu 22.04.5 LTS-64
    Kernel Details          : 6.8.0
[CPU Info]
    AMD Cpu                 : Yes
    Family                  : 0x1a    # Zen 5
    Model                   : 0x11
    Socket Count            : 2
    SMT Enabled             : Yes
    Threads per CCX         : 24
    Threads per Package     : 192
    Total number of Threads : 384 (Online 384)
[PERF Features Availability]
    Core PMC                : Yes (6 counters per core)
    L3 PMC                  : Yes (6 counters per CCX)
    DF PMC                  : Yes (4 counters per node)
    UMC PMC                 : Yes (4 counters per DDR channel)
[IBS Features Availability]
    IBS                     : Yes
[Hypervisor Info]
    Hypervisor Enabled      : No
```

---

### 19.4 `-m ipc`：IPC / CPI / 利用率

```bash
AMDuProfPcm -m ipc -a -A system,package -d 5
```

输出头部（Header）：
```
CORE METRICS
System (Aggregated) | Package (Aggregated)-0 | Package (Aggregated)-1
Utilization(%), System time(%), User time(%), Eff Freq(MHz),
IPC(Sys+User), IPC(Sys), IPC(User), CPI(Sys+User), Giga Instr/s,
Locked Instr(pti), Retired Branches(pti), Branches Mispredicted(pti)
```

实测数据行（空载基线）：
```
# System | Pkg-0 | Pkg-1
Utilization(%):    20.93   22.89   18.96
Eff Freq(MHz):   1579.09 1582.18 1575.33
IPC(Sys+User):     0.51    0.51    0.50
CPI(Sys+User):     1.96    1.94    1.98
Giga Instr/s:     62.82   34.85   27.97
Branches Mispredicted(pti): 0.83  0.77  0.91
```

> 空载下 IPC ≈ 0.5，Eff Freq ≈ 1580 MHz（远低于 P0=2300 MHz），说明 CPU 处于低功耗 idle 状态，符合预期。

---

### 19.5 `-m memory` vs `-m umc`：内存带宽的两种视角

`-m memory` 和 `-m umc` 都能报告内存带宽，但来自不同 PMC 域、侧重点不同：

| | `-m memory` | `-m umc` |
|-|------------|---------|
| **PMC 域** | DF PMC（Data Fabric 计数器） | UMC PMC（内存控制器计数器） |
| **计数器属性** | 精确计数（实际传输字节） | 估算值（列名前缀 `Est`） |
| **独有信息** | Local/Remote DRAM Write 区分；逐字母通道（Ch-A~L） | 逐 UMC 控制器编号（Umc-0~11） |
| **代际支持** | Zen 2+ | **Zen 5 独有** |
| **聚合粒度** | System / Package / 逐通道 | System / Package / 逐 UMC（`--no-aggr`） |
| **典型用途** | 内存带宽诊断、NUMA 跨 socket 写流量 | 验证各 UMC 控制器负载是否均衡 |

**`-m memory`（DF METRICS）：**

```bash
AMDuProfPcm -m memory -a -A system,package -d 5
```

```
DF METRICS
System(Aggregated) | Package-0 | Package-1
Total Mem Bw(GB/s), Total Mem RdBw(GB/s), Total Mem WrBw(GB/s),
Local DRAM Write Data Bytes(GB/s), Remote DRAM Write Data Bytes(GB/s),
Mem Ch-A RdBw/WrBw, Mem Ch-B RdBw/WrBw, ... Mem Ch-L RdBw/WrBw   # 12 通道
```

> `Local DRAM Write` vs `Remote DRAM Write` 是 `-m memory` 独有的跨 socket 写流量区分，用于判断写密集型负载是否产生 NUMA 跨节点写。

**`-m umc`（UMC METRICS，Zen 5 独有）：**

```bash
AMDuProfPcm -m umc -a -A system,package -d 5
```

```
UMC METRICS
System(Aggregated) | Package(Aggregated)-0 | Package(Aggregated)-1
Total Est Mem Bw(GB/s), Total Est Mem RdBw(GB/s), Total Est Mem WrBw(GB/s)

# 实测（空载，5 采样行）：
System:  0.09 / 0.06 / 0.04
         0.08 / 0.04 / 0.04（稳定）
```

逐 UMC 控制器（`--no-aggr`）：

```bash
AMDuProfPcm -m umc --no-aggr -d 5
```

```
UMC METRICS
Umc-0 | Umc-1 | Umc-2 | ... | Umc-11
Total Est Mem Bw(GB/s), Total Est Mem RdBw(GB/s), Total Est Mem WrBw(GB/s)
# Socket-0 对应 Umc-0~11，Socket-1 对应 Umc-12~23（24 通道合计）
```

**实际使用建议：**
- **日常带宽诊断**：优先用 `-m memory`，数据精确，且有 Local/Remote DRAM Write 区分。
- **Zen 5 通道均衡性排查**：用 `-m umc --no-aggr`，可看到每个 UMC 控制器是否负载不均（如某通道异常高/低可能指示内存条故障或 NUMA 分配倾斜）。

---

### 19.6 `-m l3`：L3 缓存

**`-m l3` 单独使用：**

```bash
AMDuProfPcm -m l3 -a -A system,package -d 5
# Info: Collect "ipc" along with "l3" for L3 pti metrics.
```

输出列（每聚合级 6 列，**无 pti 归一化列**）：
```
L3 METRICS
System(Aggregated) | Package(Aggregated)-0 | Package(Aggregated)-1
L3 Access,  L3 Miss,  L3 Miss%,  L3 Hit%,  Ave L3 Miss Latency(ns),  Potential Mem BW Saving(GB/s)
```

实测（空载，5 个 1s 采样，System | Pkg-0 | Pkg-1）：
```
# 采样 1：
System:  1,014,422 / 767,126  75.62%  24.38%  218.41 ns
Pkg-0:     745,742 / 548,369  73.53%  26.47%  197.45 ns
Pkg-1:     268,680 / 218,757  81.42%  18.58%  264.48 ns

# 采样 2–5（System 行）：
 332,540 / 221,321  66.55%  33.45%  208.30 ns
 337,424 / 264,271  78.32%  21.68%  228.19 ns
 621,142 / 552,020  88.87%  11.13%  222.42 ns
 191,199 / 136,196  71.23%  28.77%  240.67 ns
```

> 空载 L3 Miss Rate 波动 66–89%，**Ave L3 Miss Latency 约 190–265 ns**。
> 这是 L3 miss 后的完整往返时间（L3 判断 + 内存请求 + 数据返回），包含排队等待，非纯 DRAM 访问延迟。
>
> **重要：** `-m l3` 单独使用**不包含** `L3 Access(pti)` 和 `L3 Miss(pti)` 这两列（per-thousand-instructions 归一化）。这正是工具提示 `Info: Collect "ipc" along with "l3" for L3 pti metrics` 的原因——需要 IPC 指令计数才能计算 pti。

**`-m ipc,l3` 联合采集（推荐，可获得 pti 归一化列）：**

```bash
AMDuProfPcm -m ipc,l3 -a -A system,package -d 5
```

联合采集后 L3 METRICS 新增 `L3 Access(pti)` 和 `L3 Miss(pti)` 两列（每聚合级共 8 列）：
```
L3 Access,  L3 Miss,  L3 Access(pti),  L3 Miss(pti),
L3 Miss%,  L3 Hit%,  Ave L3 Miss Latency(ns),  Potential Mem BW Saving(GB/s)
```

实测（空载，第 1 采样行）：
```
# System：
L3 Access: 3,848,530   L3 Miss: 3,770,683
L3 Access(pti): 0.06   L3 Miss(pti): 0.06
L3 Miss%: 97.98%       L3 Hit%: 2.02%
Ave L3 Miss Latency: 352.93 ns

# Package-0：
L3 Access: 1,870,450   L3 Miss: 1,848,051
L3 Miss%: 98.80%       Ave L3 Miss Latency: 377.68 ns

# Package-1：
L3 Access: 1,978,080   L3 Miss: 1,922,632
L3 Miss%: 97.20%       Ave L3 Miss Latency: 330.18 ns
```

> **两次采集 Miss Latency 不同（190–265 ns vs 330–400 ns）属正常现象**——空载时 kernel idle 路径的 L3 访问完全随机，每次运行时系统活动稍有不同即可造成较大差异。真正有意义的 latency 分析应在**固定负载**（`taskset` 绑核）下进行。

---

### 19.7 `-m dc`：Data Cache Fill 来源分布

```bash
AMDuProfPcm -m dc -a -A system,package -d 5
```

输出列（每聚合级 14 列）：
```
All DC Fills(pti)
DC Fills From Local L2(pti)
DC Fills From Local L3 or different L2 in same CCX(pti)
DC Fills From another CCX in same node(pti)
DC Fills From Local Memory or I/O(pti)
DC Fills From another CCX in remote node(pti)
DC Fills From Remote Memory or I/O(pti)
Remote DRAM Reads%
Demand DC Fills From Local L2(pti)
Demand DC Fills From Local L3 or different L2 in same CCX(pti)
Demand DC Fills From another CCX in same node(pti)
Demand DC Fills From Local Memory or I/O(pti)
Demand DC Fills From another CCX in remote node(pti)
Demand DC Fills From Remote memory or I/O(pti)
```

> 空载基线：`Remote DRAM Reads% ≈ 0.01%`，说明几乎无跨 socket 远端内存访问，NUMA 亲和性良好。

---

### 19.8 `-m pipeline_util`：自顶向下 pipeline 利用率

```bash
AMDuProfPcm -m pipeline_util -a -A system -d 5
```

```
CORE METRICS (System Aggregated)
Total_Dispatch_Slots, SMT_Disp_contention,
Frontend_Bound, Bad_Speculation, Backend_Bound, Retiring,
Frontend_Bound.Latency, Frontend_Bound.BW,
Bad_Speculation.Mispredicts, Bad_Speculation.Pipeline_Restarts,
Backend_Bound.Memory, Backend_Bound.CPU,
Retiring.Fastpath, Retiring.Microcode

# 实测（空载基线，% slots）：
Frontend_Bound:    80.73%  (Latency 70.71%, BW 10.02%)
Bad_Speculation:    0.56%  (Mispredicts 0.23%)
Backend_Bound:      7.75%  (Memory 7.11%, CPU 0.64%)
Retiring:           8.72%  (Fastpath 6.26%, Microcode 2.46%)
```

> 空载下 Frontend_Bound 极高（~80%），这是正常现象：CPU 大部分时间在等待 kernel idle 循环指令，Frontend Latency 表现为 L1I/L2I 取指延迟，非工作负载下性能分析意义有限。

---

### 19.9 `-m fp`：浮点吞吐量

```bash
AMDuProfPcm -m fp -a -A system -d 5
```

```
CORE METRICS (System Aggregated)
Retired SSE/AVX Flops(GFLOPs), FP Dispatch Faults(pti),
Mixed SSE/AVX Stalls(pti), AVX-512 Instr Dispatched,
SSE/AVX 256b Instr Dispatched, SSE/AVX 128b Instr Dispatched,
Retired FP Ops By Width, Packed 512-bit Int/Float Ops

# 实测（空载）：GFLOPs ≈ 0，Mixed Stalls = 0（无浮点工作负载）
```

---

### 19.10 `-m avx_imix`：SIMD 向量宽度分布

```bash
AMDuProfPcm -m avx_imix -a -A system -d 5
```

```
# 实测（空载，多行采样）：
Packed 512-bit FP Ops Retired(%):  19.70 / 3.91 / 2.36 / 9.50 / 1.65
Packed 256-bit FP Ops Retired(%):   9.09 / 1.69 / 0.73 / 5.41 / 0.96
Packed 128-bit FP Ops Retired(%):  70.70 / 58.29/ 57.34/ 67.60/ 58.49
Scalar/MMX/x87(%):                  0.51 / 36.11/ 39.57/ 17.49/ 38.90
```

> 空载时绝大多数 FP 指令为 128-bit（kernel/libc 的小数运算），无 HPC 工作负载，数据仅反映系统背景噪声。

---

### 19.11 `-m xgmi`：Socket 间互联带宽

```bash
AMDuProfPcm -m xgmi -a -A system,package -d 5
```

```
DF METRICS
System(Aggregated) | Package-0 | Package-1
xGMI Outbound Data Bytes(GB/s)

# 实测（空载）：所有采样行均为 0.00 GB/s
```

> 空载下无跨 socket 流量，xGMI 链路静默。有 MPI 或 NUMA 跨节点访问时可见流量。

---

### 19.12 `-m ccm_bw`：CCX 跨 socket 读写带宽

```bash
AMDuProfPcm -m ccm_bw -a -A system,package -d 5
```

```
DF METRICS
System(Aggregated) | Package-0 | Package-1
Local Inbound Read Data Bytes(GB/s), Remote Inbound Read Data Bytes(GB/s)

# 实测（空载）：
0.02, 0.00,  0.00, 0.00,  0.01, 0.00
0.01, 0.00,  0.00, 0.00,  0.00, 0.00
0.01, 0.00,  0.00, 0.00,  0.00, 0.00
```

---

### 19.13 `-m cxl`：CXL 内存带宽

```bash
AMDuProfPcm -m cxl -a -A system -d 5
```

```
DF METRICS (System Aggregated)
Total CXL Memory BW(GB/s), Total CXL Read BW(GB/s), Total CXL Write BW(GB/s)

# 实测：0.00 / 0.00 / 0.00（本机无 CXL 设备）
```

---

### 19.14 `-m swpfdc` / `-m hwpfdc`：软硬件预取效果

```bash
AMDuProfPcm -m swpfdc -a -A system -d 5
AMDuProfPcm -m hwpfdc -a -A system -d 5
```

```
# swpfdc（软件预取触发的 DC Fill 来源分布，空载）：
SwPf DC Fills From DRAM or IO remote node(pti):  0.00
SwPf DC Fills From CCX Cache remote node(pti):   0.00
SwPf DC Fills From DRAM or IO local node(pti):   0.00
SwPf DC Fills From Cache another CCX local(pti): 0.00
SwPf DC Fills From L3 or diff L2 same CCX(pti):  0.00
SwPf DC Fills From L2(pti):                      0.00

# hwpfdc（硬件预取，空载）：
HwPf DC Fills From L2(pti): 0.01（极少量 HW 预取命中 L2）
其余来源：0.00
```

---

### 19.15 `-m l1` / `-m l2`：L1/L2 缓存访问

```bash
AMDuProfPcm -m l1 -a -A system -d 5
```

```
CORE METRICS (System Aggregated)
Op Cache Fetch Miss Ratio, IC Miss(pti), DC Access(pti)

# 实测（稳定值）：
Op Cache Fetch Miss Ratio: 0.14
IC Miss(pti):              0.31–0.35
DC Access(pti):          573.92–574.57
```

```bash
AMDuProfPcm -m l2 -a -A system -d 5
```

```
CORE METRICS (System Aggregated)
L2 Access(pti), L2 Access from IC Miss(pti), L2 Access from DC Miss(pti),
L2 Access from L2 HWPF(pti), L2 Miss(pti), L2 Miss from DC Miss(pti),
L2 Hit(pti), L2 Hit from DC Miss(pti)

# 实测（稳定值）：
L2 Access(pti):           6.22–6.24
L2 Miss from DC Miss(pti): 0.04       # ← L2 miss 极低
L2 Hit from DC Miss(pti):  5.82–5.83  # ← 绝大多数 DC miss 在 L2 命中
```

---

### 19.16 `-m tlb`：TLB 缺失

```bash
AMDuProfPcm -m tlb -a -A system -d 5
```

```
CORE METRICS (System Aggregated)
L1 ITLB Miss(pti), L2 ITLB Miss(pti), L1 DTLB Miss(pti), L2 DTLB Miss(pti)

# 实测（空载）：所有指标均为 0.00
```

---

### 19.17 `-m cache_miss`：综合 cache miss

```bash
AMDuProfPcm -m cache_miss -a -A system -d 5
```

```
CORE METRICS (System Aggregated)
L1 DC Miss(pti), L2 Data Read Miss(pti), L1 IC Miss(pti), L2 Code Read Miss(pti)

# 实测（稳定值）：
L1 DC Miss(pti):      5.83–5.85   # 每千条指令约 5.8 次 L1 DC miss
L2 Data Read Miss(pti): 0.04       # 极少 L2 miss
L1 IC Miss(pti):      0.31–0.37   # L1 指令 miss
L2 Code Read Miss(pti): 0.00       # 几乎无 L2 指令 miss
```

---

### 19.18 `-m pcie` / `-m dma`：PCIe / DMA 带宽

```bash
AMDuProfPcm -m pcie -a -A system,package -d 5
AMDuProfPcm -m dma  -a -A system,package -d 5
```

```
# pcie（空载）：Total PCIE BW = 0.00 GB/s（无 DMA 活跃设备）
# dma（空载）：Total Upstream DMA Read Write = 0.00 GB/s
```

---

### 19.19 `-m ipc,l3,memory`：组合采集

```bash
AMDuProfPcm -m ipc,l3,memory -a -A system,package -d 5
```

同时输出 CORE METRICS（IPC）、L3 METRICS、DF METRICS 三个域，列数大幅增加。CSV 中各域列紧密拼接：

```
CORE METRICS ... | L3 METRICS ... | DF METRICS ...
System(Agg) | Pkg-0 | Pkg-1 | System(Agg) | Pkg-0 | Pkg-1 | System(Agg) | Pkg-0 | ...
```

> 适合一次采集全面基线，但 CSV 列数可达 80+，建议配合 `-O /tmp/out` 输出到文件再后处理。

---

### 19.20 范围过滤选项

**仅监控 CCX 0（`-c ccx=0 -A ccx`）：**

```bash
AMDuProfPcm -m ipc,l3 -c ccx=0 -A ccx -d 5
```

```
CORE METRICS | L3 METRICS
CCX(Aggregated)-0
Utilization(%), Eff Freq(MHz), IPC(Sys+User), ...
L3 Access, L3 Miss, L3 Miss%, L3 Hit%, Ave L3 Miss Latency(ns)

# 实测（空载，CCX 0）：
Utilization: 17–23%,  Eff Freq: 1504–1514 MHz
IPC: 0.58,  CPI: 1.72–1.73
L3 Miss%: 83–96%,  Ave L3 Miss Latency: 205–240 ns
```

**仅监控 Package 0（`-c package=0 -A package`）：**

```bash
AMDuProfPcm -m memory -c package=0 -A package -d 5
```

输出仅包含 Package-0 的 12 通道内存带宽（空载约 0.00–0.01 GB/s）。

**按 CCD 粒度展示（`-A ccd`）：**

```bash
AMDuProfPcm -m ipc -a -A ccd -d 5
```

Zen 5 9645 有 16 个 CCD（8/Socket），输出 16 列 CCD 聚合数据。

---

### 19.21 `-C` 累积模式

```bash
AMDuProfPcm -m ipc -a -A system -d 5 -C
```

输出格式变为 **key-value 汇总**（非时间序列行）：

```
CORE METRICS
Metric,System (Aggregated)
Utilization (%),22.92
System time (%),97.58
User time (%),0.00
Eff Freq (MHz),1639.94
IPC (Sys + User),0.53
IPC (Sys),0.53
IPC (User),3.42
CPI (Sys + User),1.89
Giga Instructions Per Sec,74.40
Locked Instructions (pti),0.00
Retired Branches (pti),190.73
Retired Branches Mispredicted (pti),0.76
```

> `-C` 模式对整个 `-d` 时间段内的计数器累积求和，结果更稳定。适合稳态基准对比，消除启动阶段噪声。

---

### 19.22 错误行为验证

**`-d 0`（预期报错）：**

```bash
AMDuProfPcm -m ipc -a -d 0
# Error: Please either use '-d' option to specify profile duration
#        or specify any launch application to run.
# Error: Failed to process args.
```

**`top -A`（预期报错）：**

```bash
AMDuProfPcm top -a -A system -d 5
# Error: Command 'top' and option '-A' are not allowed together.
# Error: Failed to process args.
```

**`-u` 参数（v5.1.756 不支持）：**

```bash
AMDuProfPcm -m ipc -a -d 5 -u 1
# Error: Invalid option -u
# Info: Try using --version, --help or a command.
# Error: Failed to process args.
```

---

### 19.23 CLI 可用采集配置（`AMDuProfCLI info --list collect-configs`）

```
tbp          : Time-based Sampling
hotspots     : Hotspots（含 callstack）
assess_ext   : Assess Performance (Extended)
memory       : Cache Analysis（IBS OP）
inst_access  : Investigate Instruction Access
branch       : Investigate Branching
data_access  : Investigate Data Access
overview     : Overview
ibs          : Instruction-based Sampling
assess       : Assess Performance
cpi          : Investigate CPI（基础 IPC/CPI 分析）
threading    : Threading Analysis
```

---

*本培训材料基于 AMD uProf 用户指南（文档编号 57368）第 4 章和第 5 章编写。如需进一步参考，请查阅 AMD 处理器编程参考手册（PPR）获取逐事件寄存器详情、AMD EPYC 软件优化指南，以及 `AMDuProfPcm -h` 获取您所安装版本的完整选项列表。*
