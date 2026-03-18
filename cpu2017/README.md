# SPEC CPU 2017 使用指南

服务器：`zz@10.83.32.56`
SPEC 安装目录：`/home/zz/performance-tools/cpu2017/cpu2017/`
AMD GCC 组件包：`/home/zz/performance-tools/cpu2017/cpu2017_scripts_gcc/`

---

## 1. SPEC CPU 2017 介绍

### 1.1 来源与定位

SPEC CPU 2017 是由 SPEC（Standard Performance Evaluation Corporation）组织发布的行业标准 CPU 基准测试套件，版本 1.1.9（2022年11月发布）。SPEC 是一个由芯片厂商、服务器厂商、学术机构等组成的非营利性联盟，成员包括 AMD、Intel、ARM、IBM、HPE、Dell 等。

该套件的设计目标是通过**真实世界应用程序的源码**来评估 CPU 的计算能力，而非人工合成的微基准。43 个测试项来自科学计算、编译器、AI、图形、压缩等真实领域：

| 测试项 | 来源领域 | 语言 |
|--------|---------|------|
| 500.perlbench_r | Perl 解释器 | C |
| 502.gcc_r | GCC 编译器 | C |
| 503.bwaves_r | 计算流体力学 | Fortran |
| 507.cactuBSSN_r | 爱因斯坦方程数值求解 | C++ / Fortran |
| 519.lbm_r | 格子玻尔兹曼流体模拟 | C |
| 526.blender_r | 3D 渲染 | C++ |
| 541.leela_r | 围棋 AI | C++ |
| 557.xz_r | LZMA 压缩 | C |
| ... | | |

测试项编号规则：`5xx_r` 为 SPECrate（多核吞吐），`6xx_s` 为 SPECspeed（单线程速度）。

### 1.2 两种测试模式

| 模式 | 含义 | 适用场景 |
|------|------|---------|
| **SPECrate** (`intrate` / `fprate`) | 同时跑多个副本，测总吞吐量 | 服务器多核并发能力 |
| **SPECspeed** (`intspeed` / `fpspeed`) | 单线程或 OpenMP 并行，测单任务速度 | 单核性能、延迟敏感场景 |

AMD 组件包只支持 Rate 模式。

### 1.3 benchmark 的内部结构

每个测试项目录结构如下（以 `500.perlbench_r` 为例）：

```
benchspec/CPU/500.perlbench_r/
├── src/          # 真实应用程序源码（C/C++/Fortran）
├── data/
│   ├── test/     # 快速验证用小数据集
│   ├── train/    # 中等数据集（用于 PGO 训练）
│   └── refrate/  # 正式评分用大数据集（ref）
├── Spec/
│   └── object.pm # 描述编译方式、输入文件、运行参数
└── Docs/         # 该 benchmark 的说明文档
```

`Spec/object.pm` 中定义了源文件列表、可执行文件名、运行命令等，是 SPEC 框架调度该 benchmark 的元数据。

### 1.4 运行框架调用链

```
runcpu (shell 脚本入口)
  └── specperl bin/harness/runcpu        # SPEC 定制 Perl 解释器，驱动完整运行逻辑
        ├── specmake                      # 调用系统编译器编译 benchmark 源码
        │     └── gcc / g++ / gfortran   # 真正执行编译的编译器（由 .cfg 指定）
        ├── specinvoke                    # 按 Spec/object.pm 的规范执行编译产物
        │     └── benchspec/CPU/xxx/exe/ # 实际运行的 benchmark 可执行文件
        └── specdiff                     # 验证输出是否正确（比对 reference 结果）
```

`specperl` 是 SPEC 自带的 Perl 二进制，从 `tools/bin/linux-x86_64/tools-linux-x86_64.tar.xz` 解压安装，**不依赖系统 Perl**，保证跨平台一致性。

### 1.5 install.sh 做什么

```bash
cd /home/zz/performance-tools/cpu2017/cpu2017
./install.sh
source shrc   # 设置 $SPEC、PATH 等环境变量
```

`install.sh` 只做一件事：将 `tools/bin/linux-x86_64/tools-linux-x86_64.tar.xz` 解压到 `bin/`，得到 `specperl`、`specinvoke`、`specmake`、`specdiff` 等工具。**不编译任何 benchmark，不需要提供编译器。**

### 1.6 自行编译并运行的完整流程

```bash
# 1. 安装工具链
./install.sh && source shrc

# 2. 准备配置文件（.cfg 指定编译器和 flags）
cp config/Example-gcc-linux-x86.cfg config/my.cfg
vim config/my.cfg   # 修改编译器路径和优化 flags

# 3. 运行（首次运行自动编译源码，产物放入 exe/ 目录）
runcpu --config=my.cfg --tune=base intrate
runcpu --config=my.cfg --tune=base fprate

# 4. 结果在 result/ 目录下
ls result/
```

benchmark 可执行文件编译完后缓存在：
```
benchspec/CPU/<benchmark>/exe/<exename>_base.<label>
benchspec/CPU/<benchmark>/exe/<exename>_peak.<label>
```

后续重新运行时不会重复编译，除非源码或 flags 变化。

### 1.7 base 与 peak 的区别

| | base | peak |
|--|------|------|
| flags 约束 | 必须对所有 benchmark 用同一套 flags | 可以每个 benchmark 单独指定 flags |
| 可信度 | 高（有严格规则约束） | 低（允许更激进调优） |
| 典型用途 | 客户对比、行业报告基准 | 厂商展示最高分 |

---

## 2. AMD 组件包介绍及性能高的原理

### 2.1 组件包是什么

当前使用的 AMD GCC 组件包：`cpu2017_amd_rate_gcc15_1_znver5_A1.tar.xz`，路径：`cpu2017_scripts_gcc/`

```
cpu2017_scripts_gcc/
├── benchspec/CPU/           # 预编译好的 benchmark 可执行文件（所有 43 项）
├── config/
│   ├── amd_rate_gcc15_1_znver5_A1.cfg        # 主配置文件
│   ├── amd_rate_gcc15_1_znver5_A1_flags.inc  # 编译 flags 详细定义
│   ├── amd_rate_gcc15_1_znver5_A1_flags_portability.inc
│   └── amd_rate_gcc15_1_znver5_A1_flags_workaround.inc
├── amd_rate_gcc15_1_znver5_A_lib/
│   └── lib/                 # 运行时替换库（libamdlibm、libamdalloc 等）
├── ini_amd_rate_gcc15_1_znver5_A1.py   # 用户唯一需要编辑的配置文件
├── run_amd_rate_gcc15_1_znver5_A1.py   # 主入口脚本
└── amd_rate_gcc15_1_znver5_A1.sh       # 底层执行脚本
```

组件包的核心价值：**跳过编译步骤，直接提供已用最优参数编译好的 benchmark 可执行文件**，同时配套自动化脚本处理所有运行时系统调优。

### 2.2 为什么比自行编译性能高：五层原因

#### 原因一：GCC 15.1（发行版通常是 GCC 11–13）

组件包使用 GCC 15.1（2025年），而 Ubuntu 24.04 自带 GCC 13，RHEL 9 自带 GCC 11。GCC 15 对 znver5 的向量化器、循环调度器、IPA（过程间分析）有显著改进，仅编译器版本差距就可能带来 5–10% 的分数提升。

#### 原因二：`-march=znver5` 精准匹配 Turin 微架构

```
BASE_OPT_ROOT = -Ofast -march=znver5
```

`-march=znver5` 开启 Turin（EPYC 9005）专属指令集：AVX-512 VNNI、VAES、VPCLMULQDQ、AVX-512 BF16 等。如果用 `-march=x86-64`（默认）或 `-march=native` 但编译机器不是目标机，这些指令集完全损失。

#### 原因三：Base 模式直接使用 `-Ofast`

普通用户为保证 SPEC 合规性通常只用 `-O3`。AMD 套件 base 模式就用 `-Ofast`：

```
BASE_OPT_ROOT = -Ofast -march=znver5
```

`-Ofast` 在 `-O3` 基础上追加 `-ffast-math`（允许浮点重排）、`-fno-trapping-math` 等，对 fprate 中大量数学密集型 benchmark 提升明显。

#### 原因四：大量精调的 `--param` 调度参数（核心差距）

这是 AMD 工程师通过大量实验调出的 GCC 内部调度器参数，普通用户不会接触：

**C base — 内联与过程间分析激进化：**
```
-finline-limit=2000
--param inline-unit-growth=96
--param ipa-cp-eval-threshold=1      # IPA 常量传播几乎无门限
--param ipa-cp-unit-growth=20
--param max-inline-insns-auto=64
--param=early-inlining-insns=96
-fno-strict-aliasing
```

**C peak — 循环调度与预取调优：**
```
--param prefetch-latency=160         # 预取距离调到 Turin DDR5 延迟最优点
--param=sms-loop-average-count-threshold=80
--param=sms-max-ii-factor=15         # 软件流水线参数
--param=sms-dfa-history=10
--param=sra-max-propagations=43
--param=align-loop-iterations=35
--param=align-threshold=54471
```

**Fortran base — 向量化与 LTO 深度优化：**
```
-flto-partition=one      # 全程序单分区 LTO，最大化跨文件内联
-fstack-arrays           # 临时数组分配在栈上，避免堆分配开销
-mavx2                   # 显式开启 AVX2
--param ipa-cp-max-recursive-depth=8
--param ipa-cp-unit-growth=80
```

**全局 LTO：**
base 和 peak 均开启 `-flto`，对整个程序做链接时跨编译单元优化，这是单靠 `-O3` 无法获得的收益。

#### 原因五：AMD 专属运行时库替换系统库

cfg 中设置：
```
preENV_LD_LIBRARY_PATH = $[top]/amd_rate_gcc15_1_znver5_A_lib/lib:...
```

运行时自动注入以下替换库：

| 库文件 | 替换对象 | 优化内容 |
|--------|---------|---------|
| `libamdlibm.so` | glibc `libm` | sin/cos/exp/log 等数学函数针对 AMD 微架构重写，fprate 收益显著 |
| `libamdalloc.so.2` | glibc malloc | 内存分配器针对多路 NUMA 拓扑优化，多副本并发时减少锁竞争 |
| `libstdc++.so.6` | 系统 libstdc++ | 静态链接 GCC 15 版本，避免系统旧版本兼容问题 |
| `libgfortran.so.5` | 系统 libgfortran | 同上 |

#### 原因六：run 脚本自动化系统调优

`run_amd_rate_gcc15_1_znver5_A1.py` 在运行前自动完成：

```
透明大页（THP）   → echo always > /sys/kernel/mm/transparent_hugepage/enabled
CPU 性能模式      → cpupower frequency-set -g performance
ASLR 关闭         → echo 0 > /proc/sys/kernel/randomize_va_space
ulimit 设置       → ulimit -s unlimited; ulimit -l 2097152
NUMA 内存交织     → numactl --interleave=all runcpu ...
副本数自动计算    → 根据 cpu_info.json 中的 EPYC 型号自动确定最优 copy count
```

自行编译后手动运行 `runcpu` 时，上述设置均不会自动完成，每一项都可能影响 2–5% 的分数。

---

## 3. 如何用 AMD 组件包的配置文件自行编译高性能 benchmark

AMD 组件包中的预编译 exe 绑定了特定编译路径，无法直接在另一台机器重用，但 **flags 文件完整记录了所有编译参数**，可以用来自行编译出同等性能的 benchmark。

### 3.1 前提条件

| 前提 | 获取方式 |
|------|---------|
| GCC 15.1 | 从 GCC 官网或 AMD 工具链包安装，发行版自带版本不够 |
| AOCL（AMD Optimizing CPU Libraries） | AMD 官网免费下载，提供 `libamdlibm`、`libamdalloc` |
| SPEC CPU 2017 已安装工具链 | 运行 `install.sh` 完成 |

### 3.2 修改 cfg 开启编译模式

```bash
vim /home/zz/performance-tools/cpu2017/cpu2017_scripts_gcc/config/amd_rate_gcc15_1_znver5_A1.cfg
```

找到并修改：
```
# 改前
%define allow_build false

# 改后
%define allow_build true
```

同时修改库路径，指向 AOCL 安装位置：
```
preENV_LIBRARY_PATH = /opt/aocl/lib:/opt/aocl/lib32
```

### 3.3 将配置文件复制到 SPEC 安装目录

```bash
SPEC_DIR=/home/zz/performance-tools/cpu2017/cpu2017
GCC_PKG=/home/zz/performance-tools/cpu2017/cpu2017_scripts_gcc

# 复制配置文件
cp $GCC_PKG/config/*.cfg   $SPEC_DIR/config/
cp $GCC_PKG/config/*.inc   $SPEC_DIR/config/
cp $GCC_PKG/gcc.xml        $SPEC_DIR/config/

# 复制运行时库（用于运行阶段注入）
cp -r $GCC_PKG/amd_rate_gcc15_1_znver5_A_lib  $SPEC_DIR/
```

### 3.4 确认 GCC 15 在 PATH 中

```bash
gcc --version   # 应显示 15.1.x
which gcc       # 应指向 GCC 15 安装路径
```

如果 GCC 15 安装在非默认路径，在 flags.inc 中 CC/CXX/FC 已明确指定为 `gcc -m64` / `g++ -m64` / `gfortran -m64`，确保这些命令指向 15.1 版本即可。

### 3.5 运行编译

```bash
cd $SPEC_DIR
source shrc

# 编译并跑整数 rate（base 调优）
runcpu --config=amd_rate_gcc15_1_znver5_A1.cfg \
       --tune=base \
       --action=build \
       intrate

# 编译并跑浮点 rate
runcpu --config=amd_rate_gcc15_1_znver5_A1.cfg \
       --tune=base \
       --action=build \
       fprate
```

`--action=build` 只编译不运行，产物保存在各 benchmark 的 `exe/` 目录。去掉此参数则编译后直接运行。

### 3.6 运行时手动补充系统调优

自行运行 runcpu 时，run 脚本的自动系统调优不会生效，需手动执行：

```bash
# 透明大页
echo always | tee /sys/kernel/mm/transparent_hugepage/enabled
echo always | tee /sys/kernel/mm/transparent_hugepage/defrag

# CPU 性能模式
cpupower frequency-set -g performance

# 关闭 ASLR
echo 0 > /proc/sys/kernel/randomize_va_space

# 栈大小与内存锁定
ulimit -s unlimited
ulimit -l 2097152

# NUMA 内存交织 + 运行
numactl --interleave=all runcpu \
    --config=amd_rate_gcc15_1_znver5_A1.cfg \
    --tune=base \
    --copies=$(nproc) \
    intrate
```

### 3.7 cfg 与 flags.inc 的关系

```
amd_rate_gcc15_1_znver5_A1.cfg          # 主文件：框架设置、路径、include 声明
  └── include: flags.inc                # 所有编译器 flags 的完整定义
        ├── CC/CXX/FC 编译器声明
        ├── BASE_OPT_ROOT / PEAK_OPT_ROOT
        ├── COPTIMIZE / CXXOPTIMIZE / FOPTIMIZE
        ├── EXTRA_LIBS / EXTRA_FLIBS
        └── 各 benchmark 的 peak 特化 flags
      include: flags_portability.inc    # 跨平台移植性 flags
      include: flags_workaround.inc     # 特定 GCC 版本的 bug 绕过 flags
```

**`flags.inc` 是全部编译秘密所在**，不需要猜测任何参数，直接使用即可完整复现 AMD 的编译策略。
