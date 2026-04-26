#!/bin/bash
# 10_smoke_8b.sh — DeepSeek-R1-Distill-Llama-8B smoke test
# MUST pass before running 20_llm_matrix.sh. Validates:
#   - sm_120 kernel path
#   - attention backend selection
#   - vLLM V1 engine boot
#   - benchmark client end-to-end
#   - generated-token accounting
#
# Two configs: TP=1 eager (baseline), TP=2 cuda_graph (CG capture, NCCL SHM)
# Total runtime: ~10-15 min if all green; longer if Triton compile from cold cache

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

# 第一道闸：runtime 就位（否则 setsid 会跑空命令，watchdog 等 600s 才超时）
require_runtime

OUT="$RESULTS_ROOT/10_smoke_8b"
mkdir -p "$OUT"

PORT=8001
SERVER_LOG="$OUT/server.log"
CLIENT_LOG="$OUT/client.log"
NUM_PROMPTS=16

[[ -d "$DEEPSEEK_8B" ]] || die "model not found: $DEEPSEEK_8B (run download_models.sh first)"

run_smoke() {
    local label="$1" tp="$2" mode="$3"
    local run_dir="$OUT/$label"
    mkdir -p "$run_dir"
    log "==> smoke run: $label (tp=$tp mode=$mode)"

    bash "$SCRIPT_DIR/lib/snapshot.sh" "$run_dir" run
    bash "$SCRIPT_DIR/lib/monitor.sh" start "$run_dir"

    nccl_env
    cuda_diag_env
    run_cache_env "$run_dir"
    # V1 is default in current vLLM; do not force VLLM_USE_V1=1.

    local mode_flag=""
    [[ "$mode" == "eager" ]] && mode_flag="--enforce-eager"

    # smoke runs on island 0 (GPUs 0-3, socket 0). Matrix tests both islands.
    export CUDA_VISIBLE_DEVICES="$(gpu_island_devs 0)"
    local numa
    numa=$(gpu_island_numa 0)

    # start server (vllm serve is current CLI; legacy api_server is deprecated)
    log "starting vLLM server (CUDA_VISIBLE_DEVICES=$CUDA_VISIBLE_DEVICES, tp=$tp)"
    cleanup_orphans 2>/dev/null
    setsid $numa "$VLLM_BIN" serve "$DEEPSEEK_8B" \
        --served-model-name smoke-8b \
        --tensor-parallel-size "$tp" \
        --dtype bfloat16 \
        --max-model-len 6144 \
        --max-seq-len-to-capture 6144 \
        --gpu-memory-utilization 0.85 \
        --disable-custom-all-reduce \
        --trust-remote-code \
        --port "$PORT" \
        $mode_flag \
        > "$run_dir/server.log" 2>&1 &
    local server_pid=$!
    echo "$server_pid" > "$run_dir/server.pid"

    # wait for ready (10 min timeout — first run includes Triton compile)
    if ! wait_for_endpoint "http://127.0.0.1:$PORT/v1/models" 600; then
        emit_status "$run_dir" "SERVER_START_TIMEOUT" "vllm server didn't ready in 600s"
        kill_pgroup "$server_pid" KILL
        cleanup_orphans
        bash "$SCRIPT_DIR/lib/monitor.sh" stop "$run_dir"
        return 1
    fi

    # capture observed mode + backend
    local observed_mode
    observed_mode=$(detect_cuda_graph_mode "$run_dir/server.log" "$mode")
    log "observed CUDA graph mode: $observed_mode (requested: $mode)"

    # benchmark client — short config (4096/2048, B=4)
    log "running benchmark client..."
    timeout 600 "$VLLM_BIN" bench serve \
        --backend openai-chat --base-url "http://127.0.0.1:$PORT" \
        --model smoke-8b \
        --tokenizer "$DEEPSEEK_8B" \
        --dataset-name random \
        --random-input-len 4096 --random-output-len 2048 \
        --random-range-ratio 1.0 \
        --num-prompts "$NUM_PROMPTS" --max-concurrency 4 \
        --ignore-eos \
        --temperature 0 \
        --save-result --result-filename "$run_dir/result.json" \
        --metric-percentiles 50,90,99 \
        > "$run_dir/client.log" 2>&1
    local client_rc=$?

    # stop server
    kill_pgroup "$server_pid" TERM
    sleep 5
    kill_pgroup "$server_pid" KILL
    cleanup_orphans
    bash "$SCRIPT_DIR/lib/monitor.sh" stop "$run_dir"

    # capture end-state
    bash "$SCRIPT_DIR/lib/snapshot.sh" "$run_dir/end_snapshot" run

    # status determination
    if (( client_rc == 124 )); then
        emit_status "$run_dir" "BENCHMARK_TIMEOUT" "client hit 600s timeout"
        return 1
    fi
    if (( client_rc != 0 )); then
        if grep -qiE 'CUDA out of memory|OOM' "$run_dir/server.log" "$run_dir/client.log" 2>/dev/null; then
            emit_status "$run_dir" "CUDA_OOM" "OOM in smoke (unexpected for 8B)"
        elif grep -qiE 'no kernel image|invalid device function' "$run_dir/server.log" 2>/dev/null; then
            emit_status "$run_dir" "BACKEND_UNSUPPORTED" "sm_120 kernel missing"
        else
            emit_status "$run_dir" "UNKNOWN_FAIL" "client rc=$client_rc"
        fi
        return 1
    fi
    if [[ "$mode" == "cuda_graph" && "$observed_mode" == "eager_fallback" ]]; then
        emit_status "$run_dir" "CUDA_GRAPH_EAGER_FALLBACK" "requested CG, observed eager"
        return 1
    fi

    # validate result.json has real numbers
    local out_tput
    out_tput=$(python3 -c "import json; print(json.load(open('$run_dir/result.json'))['output_throughput'])" 2>/dev/null)
    if [[ -z "$out_tput" || "$out_tput" == "0" || "$out_tput" == "0.0" ]]; then
        emit_status "$run_dir" "UNKNOWN_FAIL" "result.json output_throughput=0"
        return 1
    fi
    log "smoke $label: output_throughput=$out_tput tok/s"
    emit_status "$run_dir" "PASS" "output_throughput=$out_tput tok/s observed_mode=$observed_mode"
    return 0
}

# run two smoke configs
run_smoke "tp1_eager" 1 eager || die "smoke tp1_eager failed — fix before matrix"
run_smoke "tp2_graph" 2 cuda_graph || log "WARN: tp2_graph failed but tp1 passed; matrix may still proceed for TP=8 eager"

# overall status: if any tp1_eager passed, the stack is at least usable
if [[ -f "$OUT/tp1_eager/status.json" ]] && \
   grep -q '"status": "PASS"' "$OUT/tp1_eager/status.json"; then
    emit_status "$OUT" "PASS" "tp1_eager passed; matrix can proceed"
    log "==> SMOKE PASSED. Run 20_llm_matrix.sh next."
    exit 0
else
    emit_status "$OUT" "UNKNOWN_FAIL" "tp1_eager did not pass"
    exit 1
fi
