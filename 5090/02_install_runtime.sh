#!/bin/bash
# 02_install_runtime.sh — 一次性把 cuda_vllm 装到能跑 5090 的状态
# 假设：cuda_vllm 是几乎空的 conda env（python 已建好），其它什么都没有
# 目标：torch (Blackwell sm_120) + vLLM + SGLang + huggingface_hub
#
# 用法：
#   source ~/miniconda3/bin/activate cuda_vllm
#   bash 02_install_runtime.sh
#
# 控制开关：
#   FORCE_UPGRADE=1     强制重装所有组件
#   SKIP_TORCH=1        torch 你自己装好了，别管
#   SKIP_VLLM=1         vllm 你自己装好了
#   SKIP_SGLANG=1       sglang 你自己装好了
#   TORCH_INDEX=...     默认 cu128 nightly（5090 sm_120 需要）
#                       覆盖示例：TORCH_INDEX=https://download.pytorch.org/whl/cu124

set -uo pipefail

if [[ -z "${CONDA_DEFAULT_ENV:-}" ]]; then
    echo "[FATAL] 当前没在 conda env 里"
    echo "        先跑：source ~/miniconda3/bin/activate cuda_vllm"
    exit 2
fi

PY="$(command -v python)"
PIP="$(command -v pip)"
echo "[info] env:    $CONDA_DEFAULT_ENV"
echo "[info] python: $PY  ($("$PY" --version 2>&1))"
echo "[info] pip:    $PIP"
[[ -z "$PY" || -z "$PIP" ]] && { echo "[FATAL] python/pip 找不到"; exit 2; }

FORCE="${FORCE_UPGRADE:-0}"
TORCH_INDEX="${TORCH_INDEX:-https://download.pytorch.org/whl/nightly/cu128}"
VLLM_EXTRA_INDEX="${VLLM_EXTRA_INDEX:-https://wheels.vllm.ai/nightly}"

# ---- 通用 helper ----
have() { "$PY" -c "import $1" 2>/dev/null; }
log()  { echo -e "\n[$(date +%H:%M:%S)] === $* ==="; }

# ---- 1. pip 自身 + 编译/构建工具 ----
log "升级 pip + 基础构建工具"
"$PIP" install --upgrade pip setuptools wheel packaging

# ---- 2. torch (cu128 nightly，5090 sm_120 必须) ----
if [[ "${SKIP_TORCH:-0}" == "1" ]]; then
    log "SKIP torch (SKIP_TORCH=1)"
elif (( FORCE == 0 )) && have torch; then
    log "torch 已在 — 跳过 ($("$PY" -c 'import torch;print(torch.__version__,"CUDA",torch.version.cuda)'))"
else
    log "安装 torch nightly (cu128) — sm_120 必须用 cu128"
    echo "    index: $TORCH_INDEX"
    "$PIP" install --pre --upgrade torch torchvision torchaudio --index-url "$TORCH_INDEX" || {
        echo "[FATAL] torch 安装失败 — 网络？或 cu128 wheel 暂时下线？"
        echo "        临时回退可试 cu126：TORCH_INDEX=https://download.pytorch.org/whl/cu126 bash $0"
        exit 3
    }
fi

# torch 装好后立刻查 sm_120 是否在 arch_list（最重要的卖点验证）
log "验证 sm_120 in torch arch list"
"$PY" - <<'PY' || { echo "[FATAL] torch 不可用"; exit 3; }
import torch
arches = torch.cuda.get_arch_list() if torch.cuda.is_available() else []
print("torch", torch.__version__, "CUDA", torch.version.cuda, "arches:", arches)
if "sm_120" not in " ".join(arches):
    print("[WARN] sm_120 不在 arch_list，5090 内核可能要走 PTX JIT，会变慢")
PY

# ---- 3. vLLM (匹配 torch nightly 的 vllm nightly) ----
if [[ "${SKIP_VLLM:-0}" == "1" ]]; then
    log "SKIP vllm (SKIP_VLLM=1)"
elif (( FORCE == 0 )) && have vllm; then
    log "vllm 已在 — 跳过 ($("$PY" -c 'import vllm;print(vllm.__version__)'))"
else
    log "安装 vllm nightly (匹配 torch nightly cu128)"
    echo "    extra-index: $VLLM_EXTRA_INDEX"
    # --pre + nightly index；--no-deps 避免 vllm 把 torch stable 拉回来覆盖 nightly
    "$PIP" install --pre --upgrade vllm \
        --extra-index-url "$VLLM_EXTRA_INDEX" || {
        echo "[FATAL] vllm 安装失败"
        echo "        看是否 torch 版本不兼容；可试 stable: pip install vllm"
        exit 3
    }
fi

# ---- 4. SGLang ----
if [[ "${SKIP_SGLANG:-0}" == "1" ]]; then
    log "SKIP sglang (SKIP_SGLANG=1)"
elif (( FORCE == 0 )) && have sglang; then
    log "sglang 已在 — 跳过 ($("$PY" -c 'import sglang;print(sglang.__version__)' 2>/dev/null || echo unknown))"
else
    log "安装 sglang[all]"
    "$PIP" install --upgrade 'sglang[all]' || {
        echo "[WARN] sglang[all] 安装失败 — 退而求其次装 sglang 主包（不带 flashinfer extra）"
        "$PIP" install --upgrade sglang || { echo "[FATAL] sglang 也装不上"; exit 3; }
    }
fi

# ---- 5. huggingface_hub (≥1.0 提供 hf CLI，01_download_models 用) ----
log "安装 huggingface_hub (≥1.0 for `hf` CLI)"
"$PIP" install --upgrade 'huggingface_hub>=1.0'

# ---- 6. 其它 bench 杂项（vllm/sglang 通常已经拖进来；这里只补漏） ----
log "补依赖：transformers, accelerate, datasets, numpy, pyyaml"
"$PIP" install --upgrade transformers accelerate datasets numpy pyyaml

# ---- 7. 全栈验证 ----
log "全栈 import 验证"
"$PY" - <<'PY' || { echo "[FATAL] 验证失败"; exit 4; }
import importlib, sys
mods = ["torch", "vllm", "sglang", "transformers", "huggingface_hub"]
miss = []
for m in mods:
    try:
        v = importlib.import_module(m)
        print(f"  {m:18s} {getattr(v, '__version__', '?')}")
    except Exception as e:
        miss.append((m, e))
        print(f"  {m:18s} FAIL: {type(e).__name__}: {e}")
import torch
print(f"  torch.cuda.is_available     {torch.cuda.is_available()}")
print(f"  torch.cuda.device_count     {torch.cuda.device_count()}")
print(f"  torch.cuda.get_arch_list    {torch.cuda.get_arch_list()}")
if miss:
    sys.exit(4)
PY

log "vllm CLI 验证"
command -v vllm || { echo "[FATAL] vllm CLI 不在 PATH"; exit 4; }
vllm --version

log "完成。下一步：bash 01_download_models.sh"
