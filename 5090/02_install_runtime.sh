#!/bin/bash
# 02_install_runtime.sh — 一次性把 vLLM + SGLang + bench 客户端装进当前 conda env
# 前置：已 source ~/miniconda3/bin/activate cuda_vllm（cuda_vllm 自带 torch + CUDA）
#
# 跑一次就够；后续 require_runtime() 会自动校验。
# 升级用 FORCE_UPGRADE=1 bash 02_install_runtime.sh。

set -uo pipefail

if [[ -z "${CONDA_DEFAULT_ENV:-}" ]]; then
    echo "[FATAL] 当前没在 conda env 里，先跑：source ~/miniconda3/bin/activate cuda_vllm"
    exit 2
fi
echo "[info] 目标 env: $CONDA_DEFAULT_ENV"
echo "[info] python: $(command -v python)"
echo "[info] pip:    $(command -v pip)"

python -c 'import torch; print("[info] torch", torch.__version__, "CUDA", torch.version.cuda)' || {
    echo "[FATAL] $CONDA_DEFAULT_ENV 没装 torch，cuda_vllm 应当自带 — 检查 env"
    exit 2
}

# 是否已装齐
need_install=0
if [[ "${FORCE_UPGRADE:-0}" == "1" ]]; then
    need_install=1
else
    python -c 'import vllm, sglang' 2>/dev/null || need_install=1
fi

if (( need_install == 0 )); then
    echo "[info] vllm + sglang 已存在；FORCE_UPGRADE=1 可强制升级"
    python -c 'import vllm, sglang; print("vllm",vllm.__version__,"sglang",sglang.__version__)'
    exit 0
fi

# vLLM —— pip 自动选与本机 torch+CUDA 匹配的 wheel
echo "[step] pip install vllm"
pip install --upgrade vllm

# SGLang —— "all" extra 把 flashinfer/sgl-kernel 等都带上（5090 sm_120 仍需注意 wheel 是否存在）
echo "[step] pip install sglang[all]"
pip install --upgrade 'sglang[all]'

# 校验
echo "[verify] import"
python -c 'import torch, vllm, sglang; print("torch",torch.__version__,"vllm",vllm.__version__,"sglang",sglang.__version__)'
echo "[verify] vllm CLI"
command -v vllm && vllm --version

echo "[done] 现在可以跑：bash 00_env_audit.sh"
