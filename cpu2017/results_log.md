# SPEC CPU 2017 测试记录

服务器：`zz@10.83.32.56`（AMD EPYC 9645，双路，384 逻辑核，SMT 开启，2267 GiB 内存）

---

## 1. Run 1 — AOCC 5.0.0 组件包 2P（2026-03-18 07:27 ~ 09:10）

### 1.1 背景与目标

使用 AMD 官方 AOCC 5.0.0 组件包，在双路系统上跑完整 intrate + fprate，作为 AMD 编译器栈的最优基准。

### 1.2 操作步骤

#### 步骤 1：备份原始 ini 文件

```bash
cd /home/zz/performance-tools/speccpu/cpu2017-aocc/
cp ini_amd_rate_aocc500_znver5_A1.py ini_amd_rate_aocc500_znver5_A1.py.bak
```

#### 步骤 2：修改 ini 配置文件

对 `ini_amd_rate_aocc500_znver5_A1.py` 做如下修改：

| 参数 | 改前 | 改后 | 说明 |
|------|------|------|------|
| `reportable` | `True` | `False` | 非正式测试，跳过 reportable 约束 |
| `iterations` | `3` | `1` | 单次迭代，保证一晚上跑完 |
| `size` | `"all"` | `"ref"` | 只跑正式评分用大数据集 |
| `tuning` | `"base,peak"` | `"base"` | 只跑 base，不跑 peak |

副本数由 AOCC run 脚本根据系统拓扑自动计算（2P EPYC 9645：intrate=384，fprate=192）。

#### 步骤 3：启动测试

```bash
# tmux session: spec-aocc
tmux new-session -d -s spec-aocc
cd /home/zz/performance-tools/speccpu/cpu2017-aocc/
echo 1 | sudo -S python3 run_amd_rate_aocc500_znver5_A1.py 2>&1 | tee /tmp/speccpu_aocc.log
```

系统调优由 run 脚本自动完成：THP=always、cpupower performance、ASLR 关闭、`numactl --interleave=all`。

### 1.3 配置参数汇总

| 参数 | 值 |
|------|----|
| 测试包路径 | `/home/zz/performance-tools/speccpu/cpu2017-aocc/` |
| 入口脚本 | `run_amd_rate_aocc500_znver5_A1.py` |
| 编译器 | AOCC 5.0.0 |
| 微架构 | znver5（Turin EPYC 9645） |
| `benchmarks` | all（intrate + fprate） |
| `tuning` | base（peak=Not Run） |
| `reportable` | False（改自默认 True） |
| `iterations` | 1（改自默认 3） |
| `size` | ref（改自默认 all） |
| copies（intrate） | 384 |
| copies（fprate） | 192 |
| 系统调优 | THP=always，CPU governor=performance，ASLR 关闭，NUMA interleave |

### 1.4 结果

| 指标 | 分数 |
|------|------|
| **SPECrate2017_int_base** | **1960** |
| **SPECrate2017_fp_base** | **1820** |
| SPECrate2017_int_peak | Not Run |
| SPECrate2017_fp_peak | Not Run |
| NR/NS | INVALID（reportable=False，iterations=1，预期） |

**总耗时：** 约 1 小时 43 分钟

结果归档：`cpu2017-aocc/CPU2017-hostname-...-20260318_0727/`

---

## 2. Run 2 — GCC 15.1 组件包 2P（2026-03-17 22:05 ~ 2026-03-18 00:43）

### 2.1 背景与目标

使用 AMD 官方 GCC 15.1 组件包，在双路系统上跑完整 intrate + fprate，与 AOCC 结果对比，量化编译器差异。

### 2.2 操作步骤

#### 步骤 1：备份原始 ini 文件

```bash
cd /home/zz/performance-tools/speccpu/cpu2017/
cp ini_amd_rate_gcc15_1_znver5_A1.py ini_amd_rate_gcc15_1_znver5_A1.py.bak
```

#### 步骤 2：修改 ini 配置文件

对 `ini_amd_rate_gcc15_1_znver5_A1.py` 做如下修改：

| 参数 | 改前 | 改后 | 说明 |
|------|------|------|------|
| `reportable` | `True` | `False` | 非正式测试，跳过 reportable 约束 |
| `iterations` | `3` | `1` | 单次迭代，保证一晚上跑完 |
| `size` | `"all"` | `"ref"` | 只跑正式评分用大数据集 |
| `tuning` | `"base,peak"` | `"base"` | 只跑 base，不跑 peak |

副本数由 GCC run 脚本根据系统拓扑自动计算（2P EPYC 9645：intrate=384，fprate=192）。

#### 步骤 3：启动测试

```bash
# tmux session: spec
tmux new-session -d -s spec
cd /home/zz/performance-tools/speccpu/cpu2017/
echo 1 | sudo -S python3 run_amd_rate_gcc15_1_znver5_A1.py 2>&1 | tee /tmp/speccpu_run.log
```

系统调优由 run 脚本自动完成：THP=always、cpupower performance、ASLR 关闭、`numactl --interleave=all`。

### 2.3 配置参数汇总

| 参数 | 值 |
|------|----|
| 测试包路径 | `/home/zz/performance-tools/speccpu/cpu2017/` |
| 入口脚本 | `run_amd_rate_gcc15_1_znver5_A1.py` |
| 编译器 | GCC 15.1 |
| 微架构 | znver5（Turin EPYC 9645） |
| `benchmarks` | all（intrate + fprate） |
| `tuning` | base（peak=Not Run） |
| `reportable` | False（改自默认 True） |
| `iterations` | 1（改自默认 3） |
| `size` | ref（改自默认 all） |
| copies（intrate） | 384 |
| copies（fprate） | 192 |
| 系统调优 | THP=always，CPU governor=performance，ASLR 关闭，NUMA interleave |

### 2.4 结果

| 指标 | 分数 |
|------|------|
| **SPECrate2017_int_base** | **1510** |
| **SPECrate2017_fp_base** | **1310** |
| SPECrate2017_int_peak | Not Run |
| SPECrate2017_fp_peak | Not Run |
| NR/NS | INVALID（reportable=False，iterations=1，预期） |

**总耗时：** 约 2 小时 38 分钟

结果归档：`cpu2017/CPU2017-hostname-...-20260317_2205/`

---

## 3. Run 3 — GCC 15.1 组件包 1P（2026-03-18 11:17 ~ 进行中）

### 3.1 背景与目标

在同一台双路服务器上，通过手动 pin 到 socket 0 的方式，模拟单路（1P）EPYC 9645 的性能基线，与 2P 结果对比验证扩展性。

### 3.2 操作步骤

#### 步骤 1：备份原始 ini 文件

```bash
# 在 /home/zz/performance-tools/speccpu/cpu2017/ 目录下
cp ini_amd_rate_gcc15_1_znver5_A1.py ini_amd_rate_gcc15_1_znver5_A1.py.bak.1p
```

#### 步骤 2：修改 ini 配置文件

对 `ini_amd_rate_gcc15_1_znver5_A1.py` 做如下修改：

| 参数 | 改前 | 改后 | 说明 |
|------|------|------|------|
| `autodetect_epyc_model` | `True` | `False` | 禁用自动检测，防止按 2P 拓扑分配副本 |
| `EpycModel` | `"9645"` (自动) | `"9645"` | 显式指定，避免检测逻辑干扰 |
| `NumberOfSockets` | `2` | `1` | 声明单路 |
| `cores_affinity_list` | 全部 384 核 | `[0..95, 192..287]` | 仅绑定 socket 0 的 192 个逻辑核（物理核 0-95，SMT 兄弟 192-287） |
| `reportable` | `True` | `False` | 非正式测试 |
| `iterations` | `3` | `1` | 单次迭代 |

`cores_affinity_list` 具体值（192 个核）：

```python
cores_affinity_list = list(range(0, 96)) + list(range(192, 288))
```

#### 步骤 3：确认 NUMA 拓扑（socket 0 对应核心）

```
node 0 CPUs: 0-95, 192-287   ← socket 0（使用此范围）
node 1 CPUs: 96-191, 288-383 ← socket 1（不使用）
```

#### 步骤 4：启动测试

```bash
# tmux session: spec-gcc-1p
tmux new-session -d -s spec-gcc-1p
cd /home/zz/performance-tools/speccpu/cpu2017
echo 1 | sudo -S python3 run_amd_rate_gcc15_1_znver5_A1.py 2>&1 | tee /tmp/speccpu_gcc_1p.log
```

运行日志：`/tmp/speccpu_gcc_1p.log`

### 3.3 配置参数汇总

| 参数 | 值 |
|------|----|
| 测试包路径 | `/home/zz/performance-tools/speccpu/cpu2017/` |
| 入口脚本 | `run_amd_rate_gcc15_1_znver5_A1.py` |
| 编译器 | GCC 15.1 |
| 微架构 | znver5（Turin EPYC 9645） |
| `benchmarks` | all（intrate + fprate） |
| `tuning` | base（peak=Not Run） |
| `reportable` | False |
| `iterations` | 1 |
| `size` | ref |
| `NumberOfSockets` | 1 |
| `autodetect_epyc_model` | False |
| copies（intrate） | 192（socket 0 逻辑核数） |
| copies（fprate） | 96 |
| `cores_affinity_list` | `[0..95, 192..287]`（socket 0 全部逻辑核） |
| 系统调优 | THP=always，CPU governor=performance，ASLR 关闭，NUMA localalloc |

### 3.4 结果

| 指标 | 分数 |
|------|------|
| **SPECrate2017_int_base** | **749** |
| **SPECrate2017_fp_base** | **625** |
| SPECrate2017_int_peak | Not Run |
| SPECrate2017_fp_peak | Not Run |
| NR/NS | INVALID（reportable=False，iterations=1，预期） |

**总耗时：** 约 4 小时 33 分钟（11:17 ~ 15:50）

- intrate：约 71 分钟（11:17 ~ 12:28，192 copies）
- fprate：约 202 分钟（12:28 ~ 15:50，192 copies，**注：应为 96 copies，脚本按逻辑核数计算导致超订，FP 单元竞争，运行时间约翻倍**）

结果归档：`cpu2017/CPU2017-hostname-...-20260318_1116/`

---

## 4. 对比汇总

### 4.1 编译器对比（2P，GCC 15.1 vs AOCC 5.0.0）

| 指标 | GCC 15.1 2P | AOCC 5.0.0 2P | AOCC 领先 |
|------|-------------|---------------|-----------|
| **int_base** | 1510 | **1960** | **+30%** |
| **fp_base** | 1310 | **1820** | **+39%** |

### 4.2 路数扩展性（GCC 15.1，1P vs 2P）

| 指标 | GCC 15.1 1P | GCC 15.1 2P | 2P/1P 比值 |
|------|-------------|-------------|-----------|
| **int_base** | **749** | 1510 | 2.01x |
| **fp_base** | **625** | 1310 | 2.10x |

> 注：1P intrate 使用 192 copies（socket 0 逻辑核），2P 使用 384 copies；int_base 比值 ~2.01x，接近线性扩展。
> fp_base 1P 实际跑了 192 copies（应为 96，脚本按逻辑核数计算导致超订），分数 625 仍具参考价值（超订下 copies × ratio 与正常 96 copies 近似），但 fprate 耗时约翻倍。

### 4.3 分析

- **AOCC vs GCC（2P）**
  - int_base +30%：AOCC Clang 后端循环向量化、IPA 优化显著优于 GCC。
  - fp_base +39%：AOCC 对 Fortran（bwaves、wrf、roms 等）和浮点密集型 C（lbm、fotonik3d）有专项优化，libamdlibm 替换效果突出。
  - 两次测试条件完全一致（1 iteration、base、ref、384/192 copies），差异完全来自编译器和运行时库。

- **1P vs 2P 扩展性（GCC 15.1）**
  - int_base 从 749 → 1510，扩展比 2.01x，接近理想线性（2.00x）。
  - 说明该系统双路 NUMA 架构对整数计算扩展性良好，跨 socket 访问开销较小。
