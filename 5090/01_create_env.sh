#!/bin/bash
# 01_create_env.sh — 创建空 conda env `cuda_vllm`（Python 3.11）
#
# 只装 python + pip。CUDA 全靠后面 02_install_runtime.sh 里的 torch wheel 自带。
# 不装 conda 的 cuda-toolkit —— 会和 pip 装的 nvidia-*-cu12 打架，污染 LD 路径。
#
# 选 3.11 不选 3.12：vllm/sglang/flashinfer/xformers 的 Blackwell-时代 nightly wheel
# 对 cp311 覆盖最稳；cp312 经常缺 wheel，会回退源码编译然后挂掉。
#
# 用法：
#   bash 01_create_env.sh             # 建 cuda_vllm，python 3.11
#   ENV_NAME=foo PY_VER=3.11 bash 01_create_env.sh
#   FORCE_RECREATE=1 bash 01_create_env.sh   # 已存在就先删掉重建
#
# 完成后必须手动激活：
#   source ~/miniconda3/bin/activate cuda_vllm
#   bash 02_install_runtime.sh

set -uo pipefail

ENV_NAME="${ENV_NAME:-cuda_vllm}"
PY_VER="${PY_VER:-3.11}"
FORCE_RECREATE="${FORCE_RECREATE:-0}"

# ---- 找 conda ----
CONDA_BIN=""
for c in "$HOME/miniconda3/bin/conda" "$HOME/anaconda3/bin/conda" "/opt/conda/bin/conda" "$(command -v conda 2>/dev/null)"; do
    if [[ -n "$c" && -x "$c" ]]; then
        CONDA_BIN="$c"
        break
    fi
done
if [[ -z "$CONDA_BIN" ]]; then
    echo "[FATAL] 找不到 conda，请先装 miniconda：https://docs.conda.io/projects/miniconda/"
    exit 2
fi
echo "[info] conda: $CONDA_BIN"

# 让 `conda activate` 可用（脚本子 shell 里通常没初始化）
CONDA_BASE="$("$CONDA_BIN" info --base)"
# shellcheck disable=SC1091
source "$CONDA_BASE/etc/profile.d/conda.sh"

# ---- 已存在的处理 ----
if "$CONDA_BIN" env list | awk '{print $1}' | grep -qx "$ENV_NAME"; then
    if [[ "$FORCE_RECREATE" == "1" ]]; then
        echo "[info] env $ENV_NAME 已存在，FORCE_RECREATE=1，先删除"
        "$CONDA_BIN" env remove -y -n "$ENV_NAME" || { echo "[FATAL] 删除失败"; exit 3; }
    else
        echo "[info] env $ENV_NAME 已存在 — 跳过创建（FORCE_RECREATE=1 强制重建）"
        echo
        echo "下一步："
        echo "    source $CONDA_BASE/bin/activate $ENV_NAME"
        echo "    bash 02_install_runtime.sh"
        exit 0
    fi
fi

# ---- 创建：只装 python + pip，channel 用 conda-forge ----
echo "[info] 创建 env: $ENV_NAME (python=$PY_VER, channel=conda-forge)"
"$CONDA_BIN" create -y -n "$ENV_NAME" -c conda-forge "python=$PY_VER" pip || {
    echo "[FATAL] conda create 失败"
    exit 3
}

# ---- 验证 ----
conda activate "$ENV_NAME" || { echo "[FATAL] activate $ENV_NAME 失败"; exit 3; }
echo "[info] python: $(command -v python)  ($(python --version 2>&1))"
echo "[info] pip:    $(command -v pip)     ($(pip --version 2>&1))"
PY_REAL=$(python -c 'import sys; print(".".join(map(str,sys.version_info[:2])))')
if [[ "$PY_REAL" != "$PY_VER" ]]; then
    echo "[WARN] 实际 python 版本 $PY_REAL ≠ 期望 $PY_VER"
fi

cat <<EOF

[OK] env $ENV_NAME 创建完成 — 当前 shell 里没自动激活
下一步（必须先在你自己的 shell 里激活）：

    source $CONDA_BASE/bin/activate $ENV_NAME
    bash 02_install_runtime.sh

EOF
