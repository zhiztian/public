#!/bin/bash
# common.sh — env block, status taxonomy, watchdog, helpers
# source from every script. NOT executable on its own.

# -------- repo / path roots --------
PUBLIC_5090_ROOT="${PUBLIC_5090_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
RESULTS_ROOT="${RESULTS_ROOT:-$PUBLIC_5090_ROOT/results}"
CACHE_ROOT="${CACHE_ROOT:-$HOME/.cache/5090_bench}"
mkdir -p "$RESULTS_ROOT" "$CACHE_ROOT"

# -------- conda env (must be activated before running benches) --------
# user is expected to: `source ~/miniconda3/bin/activate cuda_vllm` before invocation
# 兜底 python3 — 系统通常没有裸 `python` 命令；后续 require_runtime() 会强校验
PYTHON_BIN="${PYTHON_BIN:-$(command -v python || command -v python3)}"
VLLM_BIN="${VLLM_BIN:-$(command -v vllm)}"
SGLANG_LAUNCH="${SGLANG_LAUNCH:-${PYTHON_BIN:-python3} -m sglang.launch_server}"

# require_runtime: 第一次实测的根因 — 用户没激活 conda env 直接跑脚本，
# 系统 /usr/bin/python3 没装 torch/vllm，但脚本不报错继续 setsid 一个空命令，
# wait_for_endpoint 干等 600s 才超时。这里强校验：缺一个就立刻 die，
# 给出激活 conda env 的明确提示。
require_runtime() {
    local missing=()
    [[ -z "$PYTHON_BIN" || ! -x "$PYTHON_BIN" ]] && missing+=("python (PYTHON_BIN='$PYTHON_BIN')")
    [[ -z "$VLLM_BIN"   || ! -x "$VLLM_BIN"   ]] && missing+=("vllm CLI (VLLM_BIN='$VLLM_BIN')")
    if (( ${#missing[@]} > 0 )); then
        log "FATAL: 缺失运行时: ${missing[*]}"
        log "请先激活 conda env，例如:"
        log "    source ~/miniconda3/bin/activate cuda_vllm"
        log "    bash $0"
        exit 2
    fi
    if ! "$PYTHON_BIN" -c 'import torch, vllm' 2>/dev/null; then
        log "FATAL: $PYTHON_BIN 不能 import torch+vllm，conda env 激活了吗？"
        log "    source ~/miniconda3/bin/activate cuda_vllm"
        "$PYTHON_BIN" -c 'import torch, vllm' || true
        exit 2
    fi
}

# -------- compute CUDA_VISIBLE_DEVICES + matching NUMA node for a given GPU island
# island=0 → GPUs 0,1,2,3 on socket 0; island=1 → GPUs 4,5,6,7 on socket 1.
# (per GPT review: TP=4 must be tested on BOTH islands; default-binding GPUs 0-3
#  hides socket-1 perf and over-tests socket-0 path.)
gpu_island_devs() {
    case "$1" in
        0) echo "0,1,2,3" ;;
        1) echo "4,5,6,7" ;;
        all) echo "0,1,2,3,4,5,6,7" ;;
        *) echo "" ;;
    esac
}
gpu_island_numa() {
    case "$1" in
        0) echo "numactl --cpunodebind=0 --membind=0" ;;
        1) echo "numactl --cpunodebind=1 --membind=1" ;;
        all) echo "numactl --interleave=all" ;;
        *) echo "" ;;
    esac
}

# -------- model / dataset locations on target server --------
MODELS_DIR="${MODELS_DIR:-$HOME/models}"
DATASETS_DIR="${DATASETS_DIR:-$HOME/datasets}"
DEEPSEEK_8B="${DEEPSEEK_8B:-$MODELS_DIR/deepseek-r1-8b}"
DEEPSEEK_70B="${DEEPSEEK_70B:-$MODELS_DIR/deepseek-r1-70b}"
GPT_OSS_120B="${GPT_OSS_120B:-$MODELS_DIR/gpt-oss-120b}"
QWEN3_32B="${QWEN3_32B:-$MODELS_DIR/qwen3-32b}"
SHAREGPT_JSON="${SHAREGPT_JSON:-$DATASETS_DIR/sharegpt/ShareGPT_V3_unfiltered_cleaned_split.json}"

# -------- NCCL / CUDA env (per GPT cross-review §1.5, §2.4, §2.3) --------
# tinygrad fork P2P collective hangs → must disable + force SHM path
nccl_env() {
    export NCCL_P2P_DISABLE=1
    export NCCL_SHM_DISABLE=0
    export NCCL_CUMEM_HOST_ENABLE=0   # force /dev/shm path, not cuMem host
    export NCCL_DEBUG="${NCCL_DEBUG:-INFO}"
    export NCCL_DEBUG_SUBSYS="${NCCL_DEBUG_SUBSYS:-INIT,GRAPH,ENV}"
    export TOKENIZERS_PARALLELISM=false
}

# CUDA_MODULE_LOADING=EAGER: catches sm_120 missing kernels at startup not mid-run
cuda_diag_env() {
    export CUDA_MODULE_LOADING=EAGER
}

# Per-run isolated caches so we can archive triton/PTX compile artifacts
run_cache_env() {
    local run_dir="$1"
    export CUDA_CACHE_PATH="$run_dir/cache/cuda"
    export TRITON_CACHE_DIR="$run_dir/cache/triton"
    export XDG_CACHE_HOME="$run_dir/cache/xdg"
    mkdir -p "$CUDA_CACHE_PATH" "$TRITON_CACHE_DIR" "$XDG_CACHE_HOME"
}

# -------- log helpers --------
ts() { date -Is; }
log() { echo "[$(ts)] $*" >&2; }
die() { log "FATAL: $*"; exit 1; }

# -------- status taxonomy (write to <run_dir>/status.json) --------
# offline triage requires machine-readable status. one of:
#   PASS, SKIPPED_PRECHECK, SERVER_START_TIMEOUT, BENCHMARK_TIMEOUT,
#   CUDA_OOM, GPU_POISONED_AFTER_OOM, BACKEND_UNSUPPORTED, BACKEND_MISMATCH,
#   CUDA_GRAPH_CAPTURE_FAILED, CUDA_GRAPH_EAGER_FALLBACK, NCCL_INIT_FAIL,
#   NCCL_HANG_SUSPECTED, MODEL_LOAD_FAIL, QUANTIZATION_UNSUPPORTED, UNKNOWN_FAIL
emit_status() {
    local run_dir="$1" status="$2" reason="${3:-}"
    python3 - "$run_dir" "$status" "$reason" <<'PY'
import json, sys, os, time
run_dir, status, reason = sys.argv[1], sys.argv[2], sys.argv[3]
out = {"status": status, "reason": reason, "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S%z")}
os.makedirs(run_dir, exist_ok=True)
with open(os.path.join(run_dir, "status.json"), "w") as f:
    json.dump(out, f, indent=2)
PY
}

# -------- safe PGID-based kill helper (per GPT review §1.2) --------
# $! returns the leader PID of a backgrounded `setsid` cmd, but its PGID
# is the same value only for the leader. To kill the whole group safely,
# derive PGID via ps and use `kill -- -<pgid>` (with -- to disambiguate).
kill_pgroup() {
    local leader_pid="$1" sig="${2:-TERM}"
    [[ -z "$leader_pid" ]] && return 0
    local pgid
    pgid=$(ps -o pgid= -p "$leader_pid" 2>/dev/null | tr -d ' ')
    if [[ -n "$pgid" && "$pgid" =~ ^[0-9]+$ ]]; then
        kill -"$sig" -- "-$pgid" 2>/dev/null || true
    else
        kill -"$sig" "$leader_pid" 2>/dev/null || true
    fi
}

# -------- watchdog: timeout + kill process group + verify GPUs released --------
# usage: with_watchdog <timeout_sec> <run_dir> <cmd...>
with_watchdog() {
    local timeout_sec="$1" run_dir="$2"
    shift 2
    local pidfile="$run_dir/_watchdog.pid"
    setsid bash -c "$*" >> "$run_dir/_watchdog.stdout" 2>> "$run_dir/_watchdog.stderr" &
    local leader=$!
    echo "$leader" > "$pidfile"
    local elapsed=0 step=10
    while kill -0 "$leader" 2>/dev/null; do
        if (( elapsed >= timeout_sec )); then
            log "watchdog: timeout ${timeout_sec}s, killing pgroup of leader=$leader"
            kill_pgroup "$leader" TERM
            sleep 5
            kill_pgroup "$leader" KILL
            cleanup_orphans
            return 124
        fi
        sleep "$step"
        elapsed=$((elapsed + step))
    done
    wait "$leader" 2>/dev/null
    return $?
}

# Kill orphan worker processes after server crash. Empty_cache won't help if
# parent died with allocations leaked.
cleanup_orphans() {
    pkill -9 -f 'vllm.entrypoints|vllm.worker|sglang|torchrun|benchmark_serving|api_server' 2>/dev/null || true
    sleep 5
    # Detect GPU poison: memory still allocated with no visible process holding it
    local poisoned=0
    while IFS=, read -r idx mused; do
        mused=$(echo "$mused" | tr -dc '0-9')
        # >2GB allocated with no PID is suspicious
        if [[ ${mused:-0} -gt 2048 ]]; then
            local pids
            pids=$(nvidia-smi --query-compute-apps=pid --format=csv,noheader -i "$idx" 2>/dev/null | tr -d ' \n')
            if [[ -z "$pids" ]]; then
                poisoned=1
                log "GPU $idx: ${mused}MB allocated, no compute apps — possible poison"
            fi
        fi
    done < <(nvidia-smi --query-gpu=index,memory.used --format=csv,noheader,nounits 2>/dev/null)
    return $poisoned
}

# -------- wait for HTTP server ready --------
# usage: wait_for_endpoint <url> <timeout_sec>
wait_for_endpoint() {
    local url="$1" timeout="${2:-1800}"
    local elapsed=0
    while (( elapsed < timeout )); do
        if curl -sf "$url" > /dev/null 2>&1; then
            log "endpoint ready: $url ($elapsed s)"
            return 0
        fi
        sleep 10
        elapsed=$((elapsed + 10))
    done
    log "endpoint not ready after ${timeout}s: $url"
    return 1
}

# -------- detect CUDA Graph silent fallback to eager --------
# parse server log; emit observed_mode for status.json
detect_cuda_graph_mode() {
    local log_file="$1" requested="$2"
    if [[ ! -f "$log_file" ]]; then echo "unknown"; return; fi
    # vLLM/SGLang fallback signatures
    if grep -qiE 'fallback to eager|enforce.eager|cuda graph.*disable|capture.*failed|stream capture' "$log_file"; then
        echo "eager_fallback"
        return
    fi
    if grep -qiE 'capturing cudagraph|cuda graph captured|cudagraph capture' "$log_file"; then
        echo "cuda_graph"
        return
    fi
    echo "$requested"  # default to requested if no signal
}

# -------- safe-to-proceed gate: smoke test must have passed --------
require_smoke_pass() {
    local smoke_status="$RESULTS_ROOT/10_smoke_8b/status.json"
    if [[ ! -f "$smoke_status" ]]; then
        die "smoke test not run yet — run 10_smoke_8b.sh first"
    fi
    local s
    s=$(python3 -c "import json; print(json.load(open('$smoke_status'))['status'])")
    if [[ "$s" != "PASS" ]]; then
        die "smoke test status=$s, refusing to run heavy matrix"
    fi
}
