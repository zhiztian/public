#!/bin/bash
# 20_llm_matrix.sh — main LLM benchmark matrix driver
# Per GPT cross-review §0.A: ONE server process per (model, tp, engine, mode, batch).
# Per §1.1: OOM precheck before launch.
# Per §1.2: per-run watchdog timeout.
# Per §1.4: parse server log for CUDA Graph silent fallback.
#
# Matrix (after Qwen3-32B BF16 TP=2 OOM removal per GPT §0.B):
#   DeepSeek-R1-Distill-Llama-70B BF16 — TP=8 — B=1,2,4,8,16,32 — eager+graph
#   gpt-oss-120b MXFP4              — TP=4,8 — B=1,2,4,8,16,32,64,128 — eager+graph
#   Qwen3-32B BF16                  — TP=4,8 — B=1,2,4,8,16,32,64,128 — eager+graph
#   (TP=2 BF16 32B skipped — exceeds 32GB)
#
# Engines: vllm (V1) and sglang
# Datasets: random (4096/2048) primary; ShareGPT one peak run per model
#
# Estimated runtime: 40-80 GPU·hours total (multi-day with watchdog skipping)

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

require_runtime
require_smoke_pass

OUT="$RESULTS_ROOT/20_llm_matrix"
mkdir -p "$OUT"
PORT=8002

# matrix definition (CSV: label,model_dir,tp,island,batches,engine,modes)
#   island: 0 = GPUs 0-3 socket 0; 1 = GPUs 4-7 socket 1; all = all 8 GPUs
#   For TP=8 island MUST be "all". For TP=4 we test BOTH islands separately
#   (per GPT review §2.5 — without explicit CUDA_VISIBLE_DEVICES the engine
#   would always pick GPUs 0-3 and we'd never characterize socket-1 path).
# batches semicolon-separated; modes "eager", "cuda_graph", or "eager;cuda_graph"
read -r -d '' MATRIX <<'EOF' || true
ds70b_vllm,DEEPSEEK_70B,8,all,1;2;4;8;16;32,vllm,eager;cuda_graph
ds70b_sglang,DEEPSEEK_70B,8,all,1;2;4;8;16;32,sglang,eager;cuda_graph
gptoss120b_tp4i0_vllm,GPT_OSS_120B,4,0,1;2;4;8;16;32;64;128,vllm,eager;cuda_graph
gptoss120b_tp4i1_vllm,GPT_OSS_120B,4,1,1;2;4;8;16;32;64;128,vllm,eager;cuda_graph
gptoss120b_tp8_vllm,GPT_OSS_120B,8,all,1;2;4;8;16;32;64;128,vllm,eager;cuda_graph
gptoss120b_tp4i0_sglang,GPT_OSS_120B,4,0,1;2;4;8;16;32;64;128,sglang,eager;cuda_graph
gptoss120b_tp8_sglang,GPT_OSS_120B,8,all,1;2;4;8;16;32;64;128,sglang,eager;cuda_graph
qwen32b_tp4i0_vllm,QWEN3_32B,4,0,1;2;4;8;16;32;64;128,vllm,eager;cuda_graph
qwen32b_tp4i1_vllm,QWEN3_32B,4,1,1;2;4;8;16;32;64;128,vllm,eager;cuda_graph
qwen32b_tp8_vllm,QWEN3_32B,8,all,1;2;4;8;16;32;64;128,vllm,eager;cuda_graph
qwen32b_tp4i0_sglang,QWEN3_32B,4,0,1;2;4;8;16;32;64;128,sglang,eager;cuda_graph
qwen32b_tp8_sglang,QWEN3_32B,8,all,1;2;4;8;16;32;64;128,sglang,eager;cuda_graph
EOF

ISL=4096
OSL=2048
MAX_SEQ=$((ISL + OSL))
PREFLIGHT_FAILS=0

# ---- start vllm server (current `vllm serve` CLI; legacy api_server deprecated) ----
start_vllm() {
    local model="$1" tp="$2" mode="$3" run_dir="$4" batch="$5" island="$6"
    local mode_flag=""
    [[ "$mode" == "eager" ]] && mode_flag="--enforce-eager"
    local devs numa
    devs=$(gpu_island_devs "$island")
    numa=$(gpu_island_numa "$island")
    export CUDA_VISIBLE_DEVICES="$devs"

    setsid $numa "$VLLM_BIN" serve "$model" \
        --served-model-name bench-model \
        --tensor-parallel-size "$tp" \
        --dtype bfloat16 \
        --max-model-len "$MAX_SEQ" \
        --max-seq-len-to-capture "$MAX_SEQ" \
        --max-num-seqs "$batch" \
        --gpu-memory-utilization 0.85 \
        --disable-custom-all-reduce \
        --trust-remote-code \
        --port "$PORT" \
        $mode_flag \
        > "$run_dir/server.log" 2>&1 &
    echo $! > "$run_dir/server.pid"
}

# ---- start sglang server ----
start_sglang() {
    local model="$1" tp="$2" mode="$3" run_dir="$4" batch="$5" island="$6"
    local mode_flag=""
    [[ "$mode" == "eager" ]] && mode_flag="--disable-cuda-graph"
    local mem_frac="0.80"
    [[ "$mode" == "eager" ]] && mem_frac="0.88"
    local devs numa
    devs=$(gpu_island_devs "$island")
    numa=$(gpu_island_numa "$island")
    export CUDA_VISIBLE_DEVICES="$devs"

    # disable radix cache to match vLLM no-prefix-cache baseline
    setsid $numa $SGLANG_LAUNCH \
        --model-path "$model" \
        --served-model-name bench-model \
        --tp-size "$tp" \
        --dtype bfloat16 \
        --context-length "$MAX_SEQ" \
        --mem-fraction-static "$mem_frac" \
        --disable-radix-cache \
        --trust-remote-code \
        --port "$PORT" \
        $mode_flag \
        > "$run_dir/server.log" 2>&1 &
    echo $! > "$run_dir/server.pid"
}

# ---- one configuration: oom precheck + start + bench + stop + status ----
run_one() {
    local label="$1" model_dir="$2" tp="$3" island="$4" batch="$5" engine="$6" mode="$7"
    local run_dir="$OUT/$label/tp${tp}_i${island}_${engine}_${mode}_b${batch}"
    mkdir -p "$run_dir"

    log "------------------------------------------------------------"
    log "RUN: $label tp=$tp island=$island engine=$engine mode=$mode batch=$batch"
    log "------------------------------------------------------------"

    # OOM precheck
    if ! python3 "$SCRIPT_DIR/lib/oom_precheck.py" \
            "$model_dir" "$tp" "$batch" "$MAX_SEQ" "$mode" \
            > "$run_dir/precheck.json" 2>&1; then
        log "SKIP_PRECHECK (estimated OOM)"
        emit_status "$run_dir" "SKIPPED_PRECHECK" "$(python3 -c "import json;d=json.load(open('$run_dir/precheck.json'));print(f'est={d[\"estimated_total_gb_per_gpu\"]}GB lim={d[\"limit_gb_per_gpu\"]}GB')")"
        return 0
    fi

    # snapshot + monitor
    bash "$SCRIPT_DIR/lib/snapshot.sh" "$run_dir" run
    bash "$SCRIPT_DIR/lib/monitor.sh" start "$run_dir"

    # env
    nccl_env
    cuda_diag_env
    run_cache_env "$run_dir"
    # V1 is default in current vLLM; no VLLM_USE_V1 export.

    # cleanup any lingering before start
    cleanup_orphans 2>/dev/null

    # start server
    if [[ "$engine" == "vllm" ]]; then
        start_vllm "$model_dir" "$tp" "$mode" "$run_dir" "$batch" "$island"
    else
        start_sglang "$model_dir" "$tp" "$mode" "$run_dir" "$batch" "$island"
    fi
    local server_pid
    server_pid=$(cat "$run_dir/server.pid")

    # wait for ready (40 min — first run on big model includes JIT compile)
    local startup_timeout=2400
    [[ "$model_dir" == "$DEEPSEEK_70B" || "$model_dir" == "$GPT_OSS_120B" ]] && startup_timeout=3600

    if ! wait_for_endpoint "http://127.0.0.1:$PORT/v1/models" "$startup_timeout"; then
        emit_status "$run_dir" "SERVER_START_TIMEOUT" "didn't ready in ${startup_timeout}s"
        kill_pgroup "$server_pid" KILL
        cleanup_orphans
        bash "$SCRIPT_DIR/lib/monitor.sh" stop "$run_dir"
        return 1
    fi

    # detect observed CUDA Graph mode
    local observed_mode
    observed_mode=$(detect_cuda_graph_mode "$run_dir/server.log" "$mode")
    log "observed mode: $observed_mode (requested: $mode)"

    # benchmark client
    local num_prompts=$(( batch * 4 ))
    (( num_prompts < 64 )) && num_prompts=64

    # Wave-based timeout (per GPT review §2.6). Each wave processes <batch>
    # prompts in parallel and is bounded by per-request latency. With OSL=2048
    # and conservative ~50 tok/s/req under load, per-request ~= 60s; we add
    # generous slack. Hard cap 2h to avoid runaway.
    local waves=$(( (num_prompts + batch - 1) / batch ))
    local per_req_s=120
    local startup_slack=120
    local bench_timeout=$(( startup_slack + waves * per_req_s ))
    (( bench_timeout < 600 )) && bench_timeout=600
    (( bench_timeout > 7200 )) && bench_timeout=7200

    log "bench: num_prompts=$num_prompts max_concurrency=$batch waves=$waves timeout=${bench_timeout}s"

    # vllm bench serve works against any OpenAI-compatible endpoint (vLLM/SGLang)
    timeout "$bench_timeout" "$VLLM_BIN" bench serve \
        --backend openai-chat \
        --base-url "http://127.0.0.1:$PORT" \
        --model bench-model \
        --tokenizer "$model_dir" \
        --dataset-name random \
        --random-input-len "$ISL" --random-output-len "$OSL" \
        --random-range-ratio 1.0 \
        --num-prompts "$num_prompts" --max-concurrency "$batch" \
        --ignore-eos --temperature 0 \
        --save-result --result-filename "$run_dir/result.json" \
        --metric-percentiles 50,90,99 \
        > "$run_dir/client.log" 2>&1
    local rc=$?

    # stop server
    kill_pgroup "$server_pid" TERM
    sleep 10
    kill_pgroup "$server_pid" KILL
    cleanup_orphans
    bash "$SCRIPT_DIR/lib/monitor.sh" stop "$run_dir"
    bash "$SCRIPT_DIR/lib/snapshot.sh" "$run_dir/end_snapshot" run

    # classify
    if (( rc == 124 )); then
        emit_status "$run_dir" "BENCHMARK_TIMEOUT" "client hit ${bench_timeout}s"
        return 1
    fi
    if (( rc != 0 )); then
        if grep -qiE 'CUDA out of memory|OutOfMemoryError|HIP out of memory' "$run_dir/server.log" "$run_dir/client.log" 2>/dev/null; then
            emit_status "$run_dir" "CUDA_OOM" "OOM despite precheck (refine estimate)"
        elif grep -qiE 'no kernel image|invalid device function' "$run_dir/server.log" 2>/dev/null; then
            emit_status "$run_dir" "BACKEND_UNSUPPORTED" "sm_120 kernel missing"
        elif grep -qiE 'NCCL.*hang|all_reduce.*timeout' "$run_dir/server.log" 2>/dev/null; then
            emit_status "$run_dir" "NCCL_HANG_SUSPECTED" "NCCL collective timeout"
        else
            emit_status "$run_dir" "UNKNOWN_FAIL" "client rc=$rc — check logs"
        fi
        return 1
    fi
    if [[ "$mode" == "cuda_graph" && "$observed_mode" == "eager_fallback" ]]; then
        emit_status "$run_dir" "CUDA_GRAPH_EAGER_FALLBACK" "requested CG, observed eager"
        return 0  # not a hard fail; data is still valid as eager
    fi

    local out_tput tput_total ttft tpot
    out_tput=$(python3 -c "import json;d=json.load(open('$run_dir/result.json'));print(d.get('output_throughput',0))" 2>/dev/null)
    if [[ -z "$out_tput" || "$out_tput" == "0" || "$out_tput" == "0.0" ]]; then
        emit_status "$run_dir" "UNKNOWN_FAIL" "output_throughput=0 in result.json"
        return 1
    fi
    emit_status "$run_dir" "PASS" "output_tput=$out_tput observed_mode=$observed_mode"
    log "PASS: output_throughput=$out_tput tok/s"
    return 0
}

# ---- iterate matrix ----
log "starting matrix at $(ts)"
log "estimated total: 40-80 GPU·hours (skips reduce this; check status.json for triage)"

while IFS=, read -r label model_var tp island batch_csv engine mode_csv; do
    [[ -z "$label" || "$label" =~ ^# ]] && continue
    model_dir="${!model_var}"
    [[ -d "$model_dir" ]] || { log "SKIP $label: model dir missing ($model_dir)"; continue; }

    IFS=';' read -ra batches <<< "$batch_csv"
    IFS=';' read -ra modes <<< "$mode_csv"
    for mode in "${modes[@]}"; do
        for batch in "${batches[@]}"; do
            run_one "$label" "$model_dir" "$tp" "$island" "$batch" "$engine" "$mode" || true
        done
    done
done <<< "$MATRIX"

# ---- ShareGPT peak run for each model (1 config: TP=8 eager B=64) ----
log "==> ShareGPT peak runs"
for label in ds70b gptoss120b qwen32b; do
    case "$label" in
        ds70b)      model_dir="$DEEPSEEK_70B" ;;
        gptoss120b) model_dir="$GPT_OSS_120B" ;;
        qwen32b)    model_dir="$QWEN3_32B" ;;
    esac
    [[ -d "$model_dir" && -f "$SHAREGPT_JSON" ]] || { log "SKIP sharegpt $label"; continue; }
    run_dir="$OUT/sharegpt_${label}_tp8_eager_b64"
    mkdir -p "$run_dir"
    bash "$SCRIPT_DIR/lib/snapshot.sh" "$run_dir" run
    bash "$SCRIPT_DIR/lib/monitor.sh" start "$run_dir"
    nccl_env; cuda_diag_env; run_cache_env "$run_dir"
    cleanup_orphans 2>/dev/null
    start_vllm "$model_dir" 8 eager "$run_dir" 64 all
    server_pid=$(cat "$run_dir/server.pid")
    if wait_for_endpoint "http://127.0.0.1:$PORT/v1/models" 3600; then
        timeout 3600 "$VLLM_BIN" bench serve \
            --backend openai-chat --base-url "http://127.0.0.1:$PORT" \
            --model bench-model --tokenizer "$model_dir" \
            --dataset-name sharegpt --dataset-path "$SHAREGPT_JSON" \
            --num-prompts 1000 --max-concurrency 64 --request-rate inf \
            --temperature 0 \
            --save-result --result-filename "$run_dir/result.json" \
            --metric-percentiles 50,90,99 \
            > "$run_dir/client.log" 2>&1
        rc=$?
        [[ $rc -eq 0 ]] && emit_status "$run_dir" "PASS" "sharegpt peak" || \
                           emit_status "$run_dir" "UNKNOWN_FAIL" "rc=$rc"
    else
        emit_status "$run_dir" "SERVER_START_TIMEOUT" "sharegpt $label"
    fi
    kill_pgroup "$server_pid" TERM; sleep 10; kill_pgroup "$server_pid" KILL
    cleanup_orphans
    bash "$SCRIPT_DIR/lib/monitor.sh" stop "$run_dir"
done

log "matrix complete at $(ts). aggregate via 99_collect.sh"
emit_status "$OUT" "PASS" "matrix iteration complete (per-run status in subdirs)"
