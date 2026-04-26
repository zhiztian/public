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
# 已下载部分不重复占用空间；这里给的是首次安装的最坏情况预算。
need_gb=320
free_gb=$(df -BG --output=avail "$MODELS_DIR" | tail -1 | tr -dc '0-9')
echo "[info] 首装总盘 ~${need_gb} GB，当前可用 ${free_gb} GB（已下载部分不重算）"
if [[ $free_gb -lt 20 ]]; then
    echo "[FATAL] 可用空间 <20GB，连补漏都不够"; exit 1
fi
if [[ $free_gb -lt $need_gb ]]; then
    echo "[WARN] 可用空间 < ${need_gb} GB；若 4 个模型已下完，可继续；首次安装会失败"
fi

log() { echo -e "\n[$(date +%H:%M:%S)] === $* ==="; }

# 已下载短路判定：目录存在 + config.json 存在 + safetensors 数 ≥ 期望
# 满足则完全 skip（不调 hf，不联网）。脚本永远不删本地文件 —— 强制重下
# 由人工 rm -rf <target>。如果只是想 hf 自动校验补齐，设 FORCE_RESYNC=1。
FORCE_RESYNC="${FORCE_RESYNC:-0}"

is_model_complete() {
    local target="$1" expected_st="$2"
    [[ -f "$target/config.json" ]] || return 1
    local n
    n=$(find "$target" -maxdepth 1 -name '*.safetensors' 2>/dev/null | wc -l)
    (( n >= expected_st ))
}

dl_model() {
    local repo="$1" target="$2" expected_st="${3:-1}"
    if [[ "$FORCE_RESYNC" != "1" ]] && is_model_complete "$target" "$expected_st"; then
        log "SKIP $repo（已完整：config.json + ≥${expected_st} safetensors）。FORCE_RESYNC=1 可跳过此判定"
        return 0
    fi
    log "下载 $repo → $target（hf download 自带断点续传，不会重传完整文件）"
    # 注意：新 hf CLI 的 --exclude 是单值 flag，必须每个 pattern 单独写一次
    hf download "$repo" \
        --local-dir "$target" \
        --exclude '*.bin' \
        --exclude 'original/*' \
        --exclude '*.pt' \
        --exclude '*.msgpack' \
        --max-workers 8
}

# 期望 safetensors 数来自 HF 仓库实际 shard 数（用于"已完整"短路判定）
# 1. Smoke test：DeepSeek-R1-Distill-Llama-8B (~16 GB) — 与 70B 同蒸馏家族，先验软件栈
dl_model deepseek-ai/DeepSeek-R1-Distill-Llama-8B "$MODELS_DIR/deepseek-r1-8b" 4

# 2. Dense 主测试：DeepSeek-R1-Distill-Llama-70B (~140 GB)
dl_model deepseek-ai/DeepSeek-R1-Distill-Llama-70B "$MODELS_DIR/deepseek-r1-70b" 17

# 3. MoE：gpt-oss-120b MXFP4 (~65 GB) — 5090 FP4 硬件卖点
dl_model openai/gpt-oss-120b "$MODELS_DIR/gpt-oss-120b" 3

# 4. Dense：Qwen3-32B (~64 GB) — 国内主力部署模型
dl_model Qwen/Qwen3-32B "$MODELS_DIR/qwen3-32b" 14

# 5. ShareGPT 数据集 (~600 MB)
SHAREGPT_FILE="$DATASETS_DIR/sharegpt/ShareGPT_V3_unfiltered_cleaned_split.json"
if [[ "$FORCE_RESYNC" != "1" && -s "$SHAREGPT_FILE" ]]; then
    log "SKIP ShareGPT（已存在：$(du -h "$SHAREGPT_FILE" | cut -f1)）"
else
    log "下载 ShareGPT 数据集"
    hf download \
        anon8231489123/ShareGPT_Vicuna_unfiltered \
        ShareGPT_V3_unfiltered_cleaned_split.json \
        --repo-type dataset \
        --local-dir "$DATASETS_DIR/sharegpt"
fi

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
