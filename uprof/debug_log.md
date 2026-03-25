# Ctrip Debug Log

## ECET-27149 — Optimize Online Service Performance

**问题描述**：客户观察到应用 L3 cache miss latency 在 NPS=1 时为 120 ns，NPS=4 时为 140 ns，NPS=4 反而更差。应用未跨 NUMA，内存带宽未打满（~36 GB/s），需协助定位原因。

---

## 一、支线：multichase 与 AMDuProfPcm 测量关系验证

客户同时使用 multichase 和 AMDuProfPcm 测量延迟，两者数值存在差异，需要先厘清测量方法论，再判断数据是否可信。

### 1.1 测试设置

**平台**：客户 Turin 服务器，Core 24（NPS=4，NUMA 1），multichase + AMDuProfPcm

```bash
# Scenario 1：NUMA 1 其他核心空闲
numactl -C 24 -m 1 ./multichase -H -s 512 -m 1g -n 60
AMDuProfPcm -m l3 -A system,package -d 20 -c core=24

# Scenario 2：NUMA 1 其他核心施加 MLC 负载（cores 25-47, 120-143）
numactl -m 1 ./mlc --loaded_latency -R -d2000 -t600 -k25-47,120-143 -j1
numactl -C 24 -m 1 ./multichase -H -s 512 -m 1g -n 60
AMDuProfPcm -m l3 -A system,package -d 20 -c core=24
```

### 1.2 测试结果

| 指标 | S1（空闲） | S2（MLC 繁忙） |
|------|-----------|--------------|
| multichase | ~99.5 ns | 103 ns |
| uProf Ave L3 Miss Latency | ~88.5 ns | ~97.1 ns |
| 两者差值 | ~11 ns | ~6 ns |
| Remote Memory 占比 | 0.4–12%（波动） | ~0.1%（稳定） |

### 1.3 三个发现

**发现 1：multichase 与 uProf 之间 ~10 ns 差值属正常**

两者测量起止点不同：

```
CPU 发出 load 指令
    │
    ├─ L1 miss → L2 miss → L3 miss 检测     ← multichase 计时，uProf 不计
    │
    ├─ [uProf 开始] 请求发往内存控制器
    ├─ DRAM 取数据
    └─ 数据返回 L3  [uProf 结束]
    │
    ├─ L3 → L2 → L1 回填                    ← multichase 计时，uProf 不计
    └─ 数据到达寄存器，指针可用
```

差值 ~10–15 ns 是 CPU 内部流水线固定开销（L1/L2 miss 检测 + L3→L2→L1 回填路径），由微架构决定，与 DRAM 速度和负载无关，**并非测量矛盾**。

跨平台验证（Turin 9645A 空载对照）：

| 平台 | multichase | uProf Package-0 | Gap |
|------|-----------|-----------------|-----|
| 客户侧 Turin，S1 | ~99.5 ns | ~88.5 ns | ~11 ns |
| Turin 9645A 空载 | 117.3 ns | 102.95 ns | ~14 ns |

两台 Turin gap 均稳定在 10–15 ns，方法论自洽。

> **注意**：若 uProf 未加 `-c core=X`，Package 级别的平均延迟会被其他 core 的跨 NUMA miss 污染，导致数值严重虚高（实测：Milan 有业务时 Package-0 显示 290 ns，multichase 仅 95.9 ns）。应始终配合 `-c core=X` 使用。

**发现 2：同一 NUMA 节点施加内存压力，延迟升高**

S2 中 MLC 与 multichase 竞争同一 NUMA 节点的内存控制器，内存控制器请求队列变长，multichase 延迟从 99.5 ns 升至 103 ns，uProf 延迟从 88.5 ns 升至 97.1 ns。属于预期的带宽竞争行为。

**发现 3：有压力时 Remote Memory 占比反而降低，原因是内核 AutoNUMA**

S1 空闲时 remote 占比高达 12%，S2 繁忙时仅 0.1%。这是**内核行为**：Linux AutoNUMA 在系统空闲时主动 unmap 页面探测内存访问归属，产生偶发 remote 访问；高负载时内核自动抑制 AutoNUMA 探测，remote 访问消失。与体系结构无关。

> 可用 `echo 0 > /proc/sys/kernel/numa_balancing` 关闭 AutoNUMA 验证。

---

## 二、主线：NPS=1 vs NPS=4 延迟差异

### 2.1 当前数据

客户应用观测：NPS=1（120 ns）vs NPS=4（140 ns），NPS=4 更差。

当前 multichase 测试仅在 NPS=4 下进行（~99.5 ns），缺少 NPS=1 基准，无法判断 benchmark 是否能复现应用的 NPS 差异。

### 2.2 客户的附加观测与待验证假设

客户额外观测到：NPS=4 时，若对**其他空闲 NUMA 节点**施加负载，被测节点的 L3 cache miss latency 从 140 ns **降低**至 115 ns。

客户推测这是**内存控制器功耗管理**（UMC power state）导致的：NPS=4 下各节点流量低时 UMC 进入低功耗状态，新请求需先退出低功耗状态，产生额外延迟；其他节点有流量后 UMC 整体保持 active，延迟下降。

**该假设需通过以下实验验证**：

```
Step 1：NPS=4，整机空载
         → numactl --cpunodebind=0 --membind=0 ./multichase -H -s 512 -m 1g -n 60
         → 记录延迟 T1

Step 2：NPS=4，在其他 NUMA 节点（node 1/2/3）施加 MLC 负载（内存绑定到各自节点）
         → 重复 Step 1 的 multichase（仍在 node 0）
         → 记录延迟 T2

对比 T1 vs T2：
  若 T2 < T1  →  支持 UMC power state 假设
  若 T2 ≈ T1  →  UMC power state 不是主要原因，需排查其他因素
```

注意与支线 S1/S2 的区别：支线 MLC 负载在**同一 NUMA 节点内**，效果是带宽竞争导致延迟**升高**；此实验 MLC 在**其他 NUMA 节点**，假设效果是唤醒 UMC 导致延迟**降低**——两者机制不同，不可混用。

---

## 三、下一步

1. **补 NPS=1 基准**：在 NPS=1 配置下运行相同 multichase + uProf 测试，与 NPS=4（~99.5 ns）对比，判断 benchmark 层面是否存在 NPS 差异
2. **验证 UMC power state 假设**：按 2.2 节实验设计执行，对比整机空载 vs 其他节点有负载时的延迟
3. **若 benchmark 无 NPS 差异**：说明延迟差异来自应用层，需 profile 应用的线程亲和性与内存分配策略
4. **若 benchmark 有 NPS 差异**：结合 UMC 实验结果，判断是功耗管理问题还是其他硬件/固件层问题
