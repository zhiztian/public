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

## 4. Run 4 — GCC 11（系统默认）+ AMD 优化 Backport 2P（2026-03-18 17:41 ~ 22:12）

### 4.1 背景与目标

在标准 SPEC CPU2017 安装（dir1）中，使用系统 GCC 11.4.0 + 从 AMD GCC15 组件包 backport 的优化 flag 和运行时库（libamdlibm、libamdalloc），构建自定义 config，与 GCC 15.1 / AOCC 组件包结果对比，量化编译器版本差异。

### 4.2 操作步骤

#### 步骤 1：创建 GCC 11 config 文件（上传至 dir1）

在 `c:\tmp\upload_cfg.py` 中生成并通过 SFTP 上传以下文件到 `/home/zz/performance-tools/speccpu/cpu2017/config/`：

| 文件 | 说明 |
|------|------|
| `gcc11_native_rate.cfg` | 主配置，`hw_*` / `sw_*` 字段、`preENV_LD_LIBRARY_PATH` 指向 dir2 AMD 运行时库、`flagsurl` 指向 dir2 gcc.xml |
| `gcc11_native_rate_flags.inc` | 编译器 / 链接器 flag，从 AMD GCC15 config backport，去除 GCC 11 不兼容的 `-fveclib=AMDLIBM`，`-march=native`（GCC 11 最高支持 znver3），`LDOPTIMIZE` 加 `-L<dir2_libs>` |
| `gcc11_native_rate_portability.inc` | 可移植性 flag（与 AMD 原版相同） |
| `gcc11_native_rate_workaround.inc` | 各 benchmark workaround flag |

关键 flag 对比（GCC 15.1 → GCC 11）：

| 项目 | AMD GCC15 | GCC 11 本次 |
|------|-----------|-------------|
| 目标架构 | `-march=znver5` | `-march=native`（Turin 上等效 znver3 特性集）|
| 向量数学库 | `-fveclib=AMDLIBM` | 删除（GCC 11 不支持）|
| 链接器路径 | 组件包内置 | `LDOPTIMIZE = -z muldefs -L<dir2_libs>` |
| 运行时库 | libamdlibm + libamdalloc | 同（从 dir2 借用） |

#### 步骤 2：修复 libamdalloc.so 符号链接

dir2 仅有 `libamdalloc.so.2`，缺少链接器所需的 `libamdalloc.so`，导致首次编译失败：

```bash
ln -sf .../libamdalloc.so.2 .../libamdalloc.so
```

#### 步骤 3：创建并上传运行脚本

在 `c:\tmp\upload_scripts.py` 中生成并上传至 `dir1/`：

| 文件 | 说明 |
|------|------|
| `run_gcc11_2p.sh` | 系统调优 + `numactl --interleave=all runcpu --copies=384 intrate`，`--copies=192 fprate` |
| `run_gcc11_1p.sh` | 系统调优 + `numactl --localalloc --physcpubind=<socket0>` pinned，`--copies=192 intrate`，`--copies=96 fprate` |

#### 步骤 4：启动测试

```bash
# 通过 paramiko SSH 后台运行（无 tmux）
cd /home/zz/performance-tools/speccpu/cpu2017
echo 1 | sudo -S bash run_gcc11_2p.sh > /tmp/gcc11_2p_new.log 2>&1 &
```

运行日志：`/tmp/gcc11_2p_new.log`

### 4.3 配置参数汇总

| 参数 | 值 |
|------|-------|
| 测试包路径 | `/home/zz/performance-tools/speccpu/cpu2017/` |
| Config | `gcc11_native_rate.cfg` |
| 编译器 | GCC 11.4.0（Ubuntu 22.04 系统自带）|
| 架构 flag | `-march=native`（Turin = znver3-equiv in GCC 11）|
| 运行时库 | libamdlibm + libamdalloc（借自 dir2）|
| `benchmarks` | intrate + fprate |
| `tuning` | base |
| `reportable` | False |
| `iterations` | 1 |
| `size` | ref |
| copies（intrate）| 384 |
| copies（fprate）| 192 |
| 系统调优 | THP=always，CPU governor=performance，ASLR 关闭，numactl interleave |
| 结果文件 | `CPU2017.007.intrate.refrate.*`、`CPU2017.008.fprate.refrate.*` |

### 4.4 结果

| 指标 | 分数 |
|------|------|
| **SPECrate2017_int_base** | **1155** |
| **SPECrate2017_fp_base** | **891** |
| SPECrate2017_int_peak | Not Run |
| SPECrate2017_fp_peak | Not Run |
| NR/NS | INVALID（reportable=False，iterations=1，unknown flags warning，预期）|

> 分数由各 benchmark base ratio 几何均值手动计算（intrate 10项，fprate 13项），与 SPEC 官方公式一致。

**总耗时：** 约 4 小时 31 分钟（17:41 → 22:12）
- intrate 编译 + 运行：~1h47min（17:41 → 19:28）
- fprate 编译：~1h33min（19:28 → 21:01，LTO 使 blender_r 编译耗时 ~17min）
- fprate 运行：~1h11min（21:01 → 22:12）

---

## 5. Run 5 — GCC 11（系统默认）+ AMD 优化 Backport 1P（2026-03-18 23:00 ~ 2026-03-19 01:42）

### 5.1 背景与目标

在与 Run 4 完全相同的 GCC 11 + AMD backport 配置下，通过 numactl 将进程 pin 至 socket 0（192 个逻辑核），模拟单路 EPYC 9645，与 Run 4（2P）对比验证 GCC 11 下的 NUMA 扩展性，并与 Run 3（GCC 15.1 1P）对比量化编译器版本差距。

### 5.2 操作步骤

#### 步骤 1：确认 NUMA 拓扑

```
node 0 CPUs: 0-95, 192-287   ← socket 0（使用此范围）
node 1 CPUs: 96-191, 288-383 ← socket 1（不使用）
```

Socket 0 逻辑核：`SOCKET0_CPUS = 0-95（物理核）+ 192-287（SMT 兄弟）= 192 核`

#### 步骤 2：启动测试

```bash
# 通过 paramiko SSH 后台运行
cd /home/zz/performance-tools/speccpu/cpu2017
echo 1 | sudo -S bash run_gcc11_1p.sh > /tmp/gcc11_1p_new.log 2>&1 &
```

`run_gcc11_1p.sh` 关键内容：
```bash
numactl --localalloc --physcpubind="$SOCKET0" runcpu \
    --config=gcc11_native_rate.cfg --tune=base --size=ref \
    --iterations=1 --noreportable --copies=192 intrate
numactl --localalloc --physcpubind="$SOCKET0" runcpu \
    --config=gcc11_native_rate.cfg --tune=base --size=ref \
    --iterations=1 --noreportable --copies=96 fprate
```

运行日志：`/tmp/gcc11_1p_new.log`

### 5.3 配置参数汇总

| 参数 | 值 |
|------|-------|
| 测试包路径 | `/home/zz/performance-tools/speccpu/cpu2017/` |
| Config | `gcc11_native_rate.cfg` |
| 编译器 | GCC 11.4.0 |
| `NumberOfSockets` | 1（通过 numactl pin 实现）|
| `cores_affinity_list` | CPUs 0-95 + 192-287（socket 0 全部逻辑核）|
| `benchmarks` | intrate + fprate |
| `tuning` | base |
| `reportable` | False |
| `iterations` | 1 |
| `size` | ref |
| copies（intrate）| 192 |
| copies（fprate）| **96**（正确，本次无超订）|
| 系统调优 | THP=always，CPU governor=performance，ASLR 关闭，numactl localalloc |
| 结果文件 | `CPU2017.009.intrate.refrate.*`、`CPU2017.010.fprate.refrate.*` |

### 5.4 结果

| 指标 | 分数 |
|------|------|
| **SPECrate2017_int_base** | **711** |
| **SPECrate2017_fp_base** | **612** |
| SPECrate2017_int_peak | Not Run |
| SPECrate2017_fp_peak | Not Run |
| NR/NS | INVALID（reportable=False，iterations=1，预期）|

**总耗时：** 约 2 小时 42 分钟（23:00 → 01:42）
- intrate 编译（利用缓存）+ 运行：~1h13min（23:00 → 00:13）
- fprate 编译（利用缓存）+ 运行：~1h29min（00:13 → 01:42）

---

## 6. 对比汇总

### 6.1 编译器对比（2P，GCC 15.1 vs AOCC 5.0.0）

| 指标 | GCC 15.1 2P | AOCC 5.0.0 2P | AOCC 领先 |
|------|-------------|---------------|-----------|
| **int_base** | 1510 | **1960** | **+30%** |
| **fp_base** | 1310 | **1820** | **+39%** |

### 6.2 GCC 版本对比（2P，GCC 11 vs GCC 15.1）

| 指标 | GCC 11 2P | GCC 15.1 2P | GCC 15.1 领先 |
|------|-----------|-------------|---------------|
| **int_base** | 1155 | **1510** | **+31%** |
| **fp_base** | 891 | **1310** | **+47%** |

### 6.3 路数扩展性（GCC 11，1P vs 2P）

| 指标 | GCC 11 1P | GCC 11 2P | 2P/1P 比值 |
|------|-----------|-----------|-----------|
| **int_base** | **711** | 1155 | 1.62x |
| **fp_base** | **612** | 891 | 1.46x |

### 6.4 路数扩展性（GCC 15.1，1P vs 2P）

| 指标 | GCC 15.1 1P | GCC 15.1 2P | 2P/1P 比值 |
|------|-------------|-------------|-----------|
| **int_base** | **749** | 1510 | 2.01x |
| **fp_base** | **625** | 1310 | 2.10x |

> 注：GCC 15.1 1P fp_base 实际跑了 192 copies（应为 96，AMD 脚本按逻辑核数计算导致超订），分数 625 偏低，2P/1P 比值 2.10x 偏高，参考价值有限。GCC 11 1P 副本数正确（96 copies），扩展性数据更可信。

### 6.5 分析

- **AOCC vs GCC 15.1（2P）**
  - int_base +30%：AOCC Clang 后端循环向量化、IPA 优化显著优于 GCC。
  - fp_base +39%：AOCC 对 Fortran（bwaves、wrf、roms 等）和浮点密集型 C（lbm、fotonik3d）有专项优化，libamdlibm 替换效果突出。

- **GCC 15.1 vs GCC 11（2P，相同 AMD 优化 flag 框架）**
  - int_base +31%：GCC 15.1 对 znver5 有专项微架构优化（`-march=znver5` vs `-march=native`→znver3-equiv）；GCC 15 IPA / LTO 引擎也更成熟。
  - fp_base +47%：差距更大，主要来自 GCC 15 对 Fortran 的改进（`-fveclib=AMDLIBM` 加持）及 znver5 AVX-512 向量化（GCC 11 无 znver5 后端，部分向量宽度受限）。

- **GCC 11 1P vs 2P 扩展性**
  - int_base 从 711 → 1155，扩展比仅 **1.62x**（理想应为 2.00x）。
  - fp_base 从 612 → 891，扩展比 **1.46x**，Fortran 密集 benchmark（bwaves、roms 等）跨 NUMA 内存带宽争用明显。
  - 对比 GCC 15.1 的 2.01x：GCC 11 跨 socket 扩展性显著差于 GCC 15.1，推测原因为 GCC 11 LTO + IPA 在多副本场景下内存局部性优化不足，导致跨 NUMA 访问开销更突出。
