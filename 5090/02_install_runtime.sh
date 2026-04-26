#!/bin/bash
# 02_install_runtime.sh — 在已激活的 cuda_vllm env 内一次性装齐 5090 全栈
#
# 关键约束（来自客户驱动）：
#   driver 570.148.08 / CUDA 12.8 — cudart >=12.9 会让 vLLM 起不来
#   所以全程用 constraints 钉死所有 nvidia-*-cu12 < 12.9
#
# 顺序：
#   1) torch nightly cu128（带 sm_120 内核）
#   2) 锁定 torch 拉下来的精确 nvidia-*-cu12 版本
#   3) vllm nightly（带 cu128 + 不会偷偷升 cudart）
#   4) sglang（默认不带 [all]，避免 flashinfer 拉新版 CUDA）
#   5) huggingface_hub>=1.0 + transformers + accelerate + datasets
#   6) 全栈 import + cudaRuntimeGetVersion 必须 12080
#
# 用法：
#   source ~/miniconda3/bin/activate cuda_vllm
#   bash 02_install_runtime.sh
#
# 控制开关：
#   FORCE_UPGRADE=1     强制重装所有组件
#   SKIP_TORCH=1        torch 你自己装好了
#   SKIP_VLLM=1         vllm 你自己装好了
#   SKIP_SGLANG=1       sglang 你自己装好了
#   INSTALL_SGLANG_ALL=1  装 sglang[all]（默认 0，避免 flashinfer/xformers 升 CUDA）
#   TORCH_INDEX=...     默认 cu128 nightly
#   VLLM_EXTRA_INDEX=...  默认 https://wheels.vllm.ai/nightly
#   CUDART_GUARD=1      默认 1；设 0 关闭 cudart<12.9 守门（不推荐）

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
CUDART_GUARD="${CUDART_GUARD:-1}"
INSTALL_SGLANG_ALL="${INSTALL_SGLANG_ALL:-0}"

WORK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_FILE="$WORK_DIR/constraints-cu128-guard.txt"
LOCK_FILE="$WORK_DIR/constraints-runtime-lock.txt"

# ---- 通用 helper ----
have() { "$PY" -c "import $1" 2>/dev/null; }
log()  { echo -e "\n[$(date +%H:%M:%S)] === $* ==="; }

# ---- 0. 写入 cu128 守门 constraints（钉死所有 nvidia-*-cu12 < 12.9） ----
if [[ "$CUDART_GUARD" == "1" ]]; then
    log "写入 cudart<12.9 守门 constraints → $GUARD_FILE"
    cat > "$GUARD_FILE" <<'EOF'
# Driver 570.148.08 / CUDA 12.8. cudart >= 12.9 会让 vLLM 起不来。
nvidia-cuda-runtime-cu12<12.9
nvidia-cuda-nvrtc-cu12<12.9
nvidia-cuda-cupti-cu12<12.9
nvidia-cuda-nvcc-cu12<12.9
nvidia-nvjitlink-cu12<12.9
nvidia-cublas-cu12<12.9
nvidia-cufft-cu12<12.9
nvidia-curand-cu12<12.9
nvidia-cusolver-cu12<12.9
nvidia-cusparse-cu12<12.9
nvidia-cudnn-cu12<10.0
EOF
    GUARD_ARGS=(-c "$GUARD_FILE")
else
    log "[WARN] CUDART_GUARD=0，未启用 cudart<12.9 守门"
    GUARD_ARGS=()
fi

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
    "$PIP" install --pre --upgrade \
        --index-url "$TORCH_INDEX" \
        "${GUARD_ARGS[@]}" \
        torch torchvision torchaudio || {
        echo "[FATAL] torch 安装失败 — 网络？或 cu128 wheel 暂时下线？"
        echo "        临时回退可试 cu126：TORCH_INDEX=https://download.pytorch.org/whl/cu126 bash $0"
        exit 3
    }
fi

# torch 装好后立刻查 sm_120 是否在 arch_list
log "验证 sm_120 in torch arch list"
"$PY" - <<'PY' || { echo "[FATAL] torch 不可用"; exit 3; }
import torch
arches = torch.cuda.get_arch_list() if torch.cuda.is_available() else []
print("torch", torch.__version__, "CUDA", torch.version.cuda, "arches:", arches)
if "sm_120" not in " ".join(arches):
    print("[WARN] sm_120 不在 arch_list，5090 内核可能要走 PTX JIT，会变慢")
PY

# ---- 3. 生成 runtime lock（torch 拉下来的精确 nvidia-*-cu12 版本） ----
log "生成 runtime lock → $LOCK_FILE"
"$PY" - > "$LOCK_FILE" <<'PY'
import importlib.metadata as md
seen = set()
for dist in md.distributions():
    name = dist.metadata["Name"]
    lname = name.lower()
    if lname in seen:
        continue
    seen.add(lname)
    ver = dist.version
    if lname == "torch":
        print(f"{name}=={ver}")
    if lname.startswith("nvidia-") and lname.endswith("-cu12"):
        print(f"{name}=={ver}")
PY
echo "[lock] === $LOCK_FILE ==="
cat "$LOCK_FILE"
echo "[lock] ============================="

# 拼装：lock + guard 一起作为后续所有 install 的 constraints
LOCK_ARGS=(-c "$LOCK_FILE" "${GUARD_ARGS[@]}")

# 立刻报实际 cudart 版本（确认 torch cu128 给的是 12.8.x）
log "torch 安装后 cudart 版本检查"
"$PY" - <<'PY'
import importlib.metadata as md
try:
    print("nvidia-cuda-runtime-cu12 =", md.version("nvidia-cuda-runtime-cu12"))
except md.PackageNotFoundError:
    print("nvidia-cuda-runtime-cu12 = NOT INSTALLED (有问题，torch wheel 应该自带)")
PY

# ---- 4. vLLM nightly（带 lock + guard，禁止偷偷升 cudart） ----
if [[ "${SKIP_VLLM:-0}" == "1" ]]; then
    log "SKIP vllm (SKIP_VLLM=1)"
elif (( FORCE == 0 )) && have vllm; then
    log "vllm 已在 — 跳过 ($("$PY" -c 'import vllm;print(vllm.__version__)'))"
else
    log "安装 vllm nightly (匹配 torch nightly cu128，钉 cudart<12.9)"
    echo "    extra-index: $VLLM_EXTRA_INDEX"
    # --upgrade-strategy only-if-needed: 已满足就别动
    "$PIP" install --pre \
        --upgrade-strategy only-if-needed \
        --extra-index-url "$VLLM_EXTRA_INDEX" \
        "${LOCK_ARGS[@]}" \
        vllm || {
        echo "[FATAL] vllm 安装失败"
        echo "        看是否 vllm nightly 要求 cudart>=12.9 — 那就只能等 vllm 出 cu128 stable 或撤掉 GUARD"
        echo "        排查命令："
        echo "          pip install --dry-run --report /tmp/vllm-dry.json --pre --extra-index-url $VLLM_EXTRA_INDEX -c $LOCK_FILE -c $GUARD_FILE vllm"
        exit 3
    }
fi

# ---- 5. SGLang（默认只装主包，不拉 [all] 里的 flashinfer/xformers） ----
if [[ "${SKIP_SGLANG:-0}" == "1" ]]; then
    log "SKIP sglang (SKIP_SGLANG=1)"
elif (( FORCE == 0 )) && have sglang; then
    log "sglang 已在 — 跳过 ($("$PY" -c 'import sglang;print(sglang.__version__)' 2>/dev/null || echo unknown))"
else
    if [[ "$INSTALL_SGLANG_ALL" == "1" ]]; then
        log "安装 sglang[all]（INSTALL_SGLANG_ALL=1，会拉 flashinfer/xformers，可能升 cudart）"
        "$PIP" install --upgrade-strategy only-if-needed \
            "${LOCK_ARGS[@]}" \
            'sglang[all]' || {
            echo "[WARN] sglang[all] 失败 — 退化为只装主包"
            "$PIP" install --upgrade-strategy only-if-needed \
                "${LOCK_ARGS[@]}" \
                sglang || { echo "[FATAL] sglang 也装不上"; exit 3; }
        }
    else
        log "安装 sglang 主包（不带 [all]，避免拉 flashinfer 升 cudart）"
        echo "    需要 flashinfer/xformers 时，单独 INSTALL_SGLANG_ALL=1 重跑"
        "$PIP" install --upgrade-strategy only-if-needed \
            "${LOCK_ARGS[@]}" \
            sglang || { echo "[FATAL] sglang 装不上"; exit 3; }
    fi
fi

# ---- 6. huggingface_hub (≥1.0 提供 hf CLI，04_download_models 用) ----
log "安装 huggingface_hub (≥1.0 for 'hf' CLI)"
"$PIP" install --upgrade-strategy only-if-needed \
    "${LOCK_ARGS[@]}" \
    'huggingface_hub>=1.0'

# ---- 7. 其它 bench 杂项 ----
log "补依赖：transformers, accelerate, datasets, numpy, pyyaml, sentencepiece, protobuf"
"$PIP" install --upgrade-strategy only-if-needed \
    "${LOCK_ARGS[@]}" \
    transformers accelerate datasets numpy pyyaml sentencepiece protobuf

# ---- 8. pip check（依赖一致性） ----
log "pip check（依赖一致性）"
"$PIP" check || echo "[WARN] pip check 报告冲突 — 看上面行；不一定致命，但记录下来"

# ---- 9. 全栈 import + cudart 真实版本验证 ----
log "全栈 import 验证"
"$PY" - <<'PY' || { echo "[FATAL] import 验证失败"; exit 4; }
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

log "cudart 实际加载版本检查（必须是 12080 = 12.8）"
"$PY" - <<'PY' || { echo "[FATAL] cudart 检查失败"; exit 4; }
import torch, ctypes, sys
torch.cuda.init()
v = ctypes.c_int()
ctypes.CDLL("libcudart.so.12").cudaRuntimeGetVersion(ctypes.byref(v))
print(f"cudaRuntimeGetVersion = {v.value}  (12080 = 12.8, 12090 = 12.9)")
print("loaded libcudart paths:")
paths = sorted({line.split()[-1] for line in open("/proc/self/maps") if "libcudart.so" in line})
for p in paths:
    print(" ", p)
if v.value >= 12090:
    print(f"[FATAL] cudart {v.value} ≥ 12.9，会让 vLLM 起不来！")
    print(f"        重装 torch 或检查 constraints。")
    sys.exit(5)
if v.value < 12080:
    print(f"[WARN] cudart {v.value} < 12.8，对 5090 sm_120 可能有兼容性问题")
print("[OK] cudart in 12.8 range")
PY

log "vllm CLI 验证"
command -v vllm || { echo "[FATAL] vllm CLI 不在 PATH"; exit 4; }
vllm --version

log "完成。下一步：bash 03_env_audit.sh"
