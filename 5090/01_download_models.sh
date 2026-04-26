#!/bin/bash
# 5090 vLLM bench 模型/数据集下载脚本
# 用法：
#   bash download_models.sh
#
# 下载清单（~285 GB 总盘）：
#   - smoke: DeepSeek-R1-Distill-Llama-8B            (~16 GB)  软件栈验证
#   - dense: DeepSeek-R1-Distill-Llama-70B           (~140 GB) 主测试 + r9700 对照
#   - moe:   openai/gpt-oss-120b (MXFP4)             (~65 GB)  5090 FP4 卖点
#   - dense: Qwen/Qwen3-32B                          (~64 GB)  国内生产部署主力
#   - data:  ShareGPT V3                             (~0.6 GB) 测试 6-10 数据集
#
# 前置：
#   pip install -U huggingface_hub          # ≥1.0 提供 `hf` CLI（旧 huggingface-cli 已废弃）
#   hf auth login                            # 公开模型也建议 login，限速更宽
# 国内加速：export HF_ENDPOINT=https://hf-mirror.com

set -euo pipefail

MODELS_DIR="${MODELS_DIR:-$HOME/models}"
DATASETS_DIR="${DATASETS_DIR:-$HOME/datasets}"

mkdir -p "$MODELS_DIR" "$DATASETS_DIR"

command -v hf >/dev/null || {
    echo "[FATAL] hf CLI 未安装，先跑：pip install -U huggingface_hub"; exit 1; }

# 磁盘容量检查（--output=avail 单列输出，免对齐烦恼）
need_gb=320
free_gb=$(df -BG --output=avail "$MODELS_DIR" | tail -1 | tr -dc '0-9')
echo "[info] 需要 ~${need_gb} GB，当前可用 ${free_gb} GB"
if [[ $free_gb -lt $need_gb ]]; then
    echo "[FATAL] 磁盘不够"; exit 1
fi

log() { echo -e "\n[$(date +%H:%M:%S)] === $* ==="; }

dl_model() {
    local repo="$1" target="$2"
    log "下载 $repo → $target"
    # 注意：新 hf CLI 的 --exclude 是单值 flag，必须每个 pattern 单独写一次
    hf download "$repo" \
        --local-dir "$target" \
        --exclude '*.bin' \
        --exclude 'original/*' \
        --exclude '*.pt' \
        --exclude '*.msgpack' \
        --max-workers 8
}

# 1. Smoke test：DeepSeek-R1-Distill-Llama-8B (~16 GB) — 与 70B 同蒸馏家族，先验软件栈
dl_model deepseek-ai/DeepSeek-R1-Distill-Llama-8B "$MODELS_DIR/deepseek-r1-8b"

# 2. Dense 主测试：DeepSeek-R1-Distill-Llama-70B (~140 GB)
dl_model deepseek-ai/DeepSeek-R1-Distill-Llama-70B "$MODELS_DIR/deepseek-r1-70b"

# 3. MoE：gpt-oss-120b MXFP4 (~65 GB) — 5090 FP4 硬件卖点
dl_model openai/gpt-oss-120b "$MODELS_DIR/gpt-oss-120b"

# 4. Dense：Qwen3-32B (~64 GB) — 国内主力部署模型
dl_model Qwen/Qwen3-32B "$MODELS_DIR/qwen3-32b"

# 5. ShareGPT 数据集 (~600 MB)
log "下载 ShareGPT 数据集"
hf download \
    anon8231489123/ShareGPT_Vicuna_unfiltered \
    ShareGPT_V3_unfiltered_cleaned_split.json \
    --repo-type dataset \
    --local-dir "$DATASETS_DIR/sharegpt"

# 校验（用 find 而不是 glob+ls，避免 set -e/pipefail 触发）
count_st() { find "$1" -maxdepth 1 -name '*.safetensors' 2>/dev/null | wc -l; }

log "校验"
echo "DeepSeek 8B  safetensors 文件数：$(count_st "$MODELS_DIR/deepseek-r1-8b")  （期望 ~4）"
echo "DeepSeek 70B safetensors 文件数：$(count_st "$MODELS_DIR/deepseek-r1-70b") （期望 ~17）"
echo "gpt-oss-120b safetensors 文件数：$(count_st "$MODELS_DIR/gpt-oss-120b")    （期望 ~3）"
echo "Qwen3-32B    safetensors 文件数：$(count_st "$MODELS_DIR/qwen3-32b")       （期望 ~14）"
ls -la "$DATASETS_DIR/sharegpt/ShareGPT_V3_unfiltered_cleaned_split.json" || \
    echo "[WARN] ShareGPT 文件不见"

du -sh "$MODELS_DIR"/* "$DATASETS_DIR"/* 2>/dev/null || true

log "完成"
