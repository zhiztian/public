# 5090 + 9A55 Benchmark Suite

**Target platform**: 2× EPYC 9A55 (84c, Turin) × 8× RTX 5090 (Blackwell GB202, 32GB GDDR7, PCIe Gen5)
**Driver assumed**: tinygrad fork `570.148.08-p2p` (NCCL P2P collective broken — must keep `NCCL_P2P_DISABLE=1`)
**BIOS assumed**: ACS=Disabled, ReBAR enabled, IOMMU disabled, PCIe Gen5 confirmed

This is the **offline-execution script suite** for Phase 3 (LLM inference) and Phase 4 (SPEC CPU 2017). Phases 1–2 (driver, P2P, H2D, NCCL SHM) already complete.

---

## Execution order

```
0. 01_download_models.sh     # ~285 GB: 4 models + ShareGPT. Run once on first install.
1. 00_env_audit.sh           # software stack + system snapshot. ALWAYS RUN FIRST.
2. 10_smoke_8b.sh            # DeepSeek-8B smoke. Must PASS before matrix.
3. 20_llm_matrix.sh          # Phase 3 main: vLLM + SGLang × 3 models × TP × batch × {eager,graph}
4. 30_speccpu_9a55.sh        # Phase 4: AOCC 5.0 + GCC 15.1 intrate+fprate ref
5. 99_collect.sh             # Pack results/ → tar.gz + index.json, ready for git push
```

Run sequentially. Each script reads the previous one's status; smoke failure aborts matrix.

**Estimated wallclock**:
- 00: ~3 min
- 10: ~10–15 min (cold Triton cache: +20 min first time)
- 20: **40–80 GPU·hours** (≈ 3–5 days, runs unattended via watchdog)
- 30: **18–32 hours** (overnight × 2; AOCC + GCC15.1)
- 99: ~5 min

## Prerequisites on target server

**❗ 必须先激活 conda env，否则所有脚本立即 die（require_runtime 强校验）**

第一次 dry-run 踩过的坑：脚本默认 `PYTHON_BIN=$(command -v python)`，
但 Ubuntu 24.04 系统只有 `python3` 没有 `python`，导致 `$PYTHON_BIN -` 被
shell 当成命令 `-` 执行；同样 `vllm` 不在 PATH 时 `setsid numactl ... "" serve`
会让 numactl 试图执行空字符串。`require_runtime` 现在会检查
PYTHON_BIN/VLLM_BIN 都可执行 + `python -c 'import torch, vllm'` 通过。

```bash
# Conda env — 必须先激活！
source ~/miniconda3/bin/activate cuda_vllm
python -c "import torch, vllm; print(torch.cuda.get_arch_list())"  # must include sm_120

# Models — run 01_download_models.sh first (~285 GB to ~/models + ~/datasets)
#   pip install -U huggingface_hub   # provides `hf` CLI
#   hf auth login                     # public models too — looser rate limits
#   bash 01_download_models.sh
ls ~/models/deepseek-r1-8b ~/models/deepseek-r1-70b \
   ~/models/gpt-oss-120b ~/models/qwen3-32b
ls ~/datasets/sharegpt/*.json

# SPEC CPU 2017
ls ~/speccpu2017/shrc

# Compilers
ls /opt/AMD/aocc-compiler-5.0.0/setenv_AOCC.sh
ls /opt/gcc-15.1/bin/gcc
```

If any path differs, set env vars at top of script invocation:

```bash
MODELS_DIR=/data/models SPEC_HOME=/data/speccpu2017 bash 00_env_audit.sh
```

## Output layout

```
results/
├── 00_env_audit/
│   ├── identity.txt, nvidia_smi*.txt, lscpu*, dmidecode.txt
│   ├── lspci_acs_links.txt, dmesg_relevant.txt, cmdline.txt
│   ├── python_stack.txt, vllm_help.txt, sglang_help.txt
│   ├── attention_probe.json, nccl_probe.txt
│   └── status.json
├── 10_smoke_8b/
│   ├── tp1_eager/{server.log,client.log,result.json,status.json,...}
│   ├── tp2_graph/...
│   └── status.json
├── 20_llm_matrix/
│   ├── ds70b_vllm/tp8_vllm_eager_b1/...
│   ├── ds70b_vllm/tp8_vllm_eager_b2/...
│   ├── ... (per-config dirs)
│   ├── sharegpt_ds70b_tp8_eager_b64/...
│   └── status.json
└── 30_speccpu_9a55/
    ├── aocc500_9a55/{runcpu.log,CPU2017.*.txt,result_archive.tgz}
    └── gcc151_9a55/...
```

Each per-config dir contains:
Per-config dir naming: `tp{N}_i{island}_{engine}_{mode}_b{batch}/`

Each contains:
- `precheck.json` — KV memory estimate (decides RUN vs SKIP_PRECHECK)
- `server.log`, `client.log`, `result.json`
- `nvidia_smi_loop.csv`, `nvidia_smi_dmon.csv` — throttle / power / clock samples 1Hz
- `nvidia_smi.txt`, `gpu_state.csv`, `dmesg_relevant.txt` — pre-run snapshot
- `end_snapshot/` — post-run snapshot
- `status.json` — machine-readable result (see taxonomy below)

## Status taxonomy

Every run emits `status.json`. Possible values:

| status | meaning |
|---|---|
| PASS | benchmark completed, result.json has nonzero throughput |
| SKIPPED_PRECHECK | KV+weight estimate exceeds 32GB×0.85 — not run |
| SERVER_START_TIMEOUT | vLLM/SGLang didn't accept requests in budget |
| BENCHMARK_TIMEOUT | client hit timeout (request-level) |
| CUDA_OOM | OOM despite precheck — refine estimate |
| GPU_POISONED_AFTER_OOM | memory allocated with no compute apps after kill |
| BACKEND_UNSUPPORTED | "no kernel image" / "invalid device function" — sm_120 missing |
| BACKEND_MISMATCH | requested attention backend ≠ observed |
| CUDA_GRAPH_CAPTURE_FAILED | server log shows capture error |
| CUDA_GRAPH_EAGER_FALLBACK | requested CG, server fell back to eager (data still valid) |
| NCCL_INIT_FAIL | NCCL bootstrap failed |
| NCCL_HANG_SUSPECTED | collective timeout in log |
| MODEL_LOAD_FAIL | weights load failed |
| QUANTIZATION_UNSUPPORTED | MXFP4/FP4 not honored, dequantized to BF16 |
| UNKNOWN_FAIL | catch-all; see logs |

## Known landmines (already wired in)

1. **NCCL P2P collective hangs** on tinygrad fork — `nccl_env()` sets `NCCL_P2P_DISABLE=1`, `NCCL_CUMEM_HOST_ENABLE=0`, plus `--disable-custom-all-reduce` for vLLM.
2. **CUDA Graph silent fallback to eager** — `detect_cuda_graph_mode()` parses server log, emits `CUDA_GRAPH_EAGER_FALLBACK` if requested CG but observed eager.
3. **Qwen3-32B BF16 TP=2 OOM** — only TP=4 and TP=8 in matrix.
4. **gpt-oss-120b MXFP4** — script doesn't force `--dtype`; precheck assumes 0.5 byte/weight. If vLLM doesn't honor MXFP4 the run will OOM with `QUANTIZATION_UNSUPPORTED` classification.
5. **Triton/PTX first-run JIT** — startup timeout 60 min for big models.
6. **/dev/shm** size checked in 00 — NCCL SHM degrades if <16GB.
7. **GPU monitor** runs throughout; CSV captures throttle reasons.
8. **One server per config** — no batch sweeping inside a single server (KV reservation + CG capture batch list distort comparison).

## Customization knobs

In `lib/common.sh`:
- `MODELS_DIR`, `DATASETS_DIR`, individual model paths
- `PYTHON_BIN` if conda env different
- `RESULTS_ROOT` to redirect output

In `20_llm_matrix.sh`:
- `MATRIX` heredoc — 7-column CSV: `label,model_var,tp,island,batches,engine,modes`
  - `island=0` → GPUs 0-3 (socket 0); `island=1` → GPUs 4-7 (socket 1); `island=all` → all 8
  - TP=4 rows are duplicated for both islands so socket-1 NUMA path is also characterized
- `ISL`, `OSL`, `MAX_SEQ` constants
- Wave-based bench timeout: `startup + waves × per_req_s` (per_req_s=120, hard cap 2h)

In `30_speccpu_9a55.sh`:
- `SPEC_HOME`, `COPIES`
- `AOCC_CFG_NAME`, `GCC_CFG_NAME` — config templates written into SPEC `config/` dir

## Failure recovery

See [ROLLBACK.md](ROLLBACK.md) for: GPU poison, SHM saturation, hung CG capture, NCCL hang, SPEC stuck, disk full.

## Returning results

```bash
bash 99_collect.sh
# produces results_<date>.tgz and results_<date>_index.json at public/5090/
cd ..
git add 5090/results_*.tgz 5090/results_*_index.json
git commit -m "5090 bench results $(date +%Y-%m-%d)"
git push
```

The `index.json` is small (<100KB), grep-friendly, lists every run + status + key metrics. Use it for first-pass triage before unpacking the tarball.

## Cross-validation

This suite was generated by Claude Opus 4.7 + cross-reviewed by GPT-5.5
(2026-04-25 session). Review notes incorporated:
- one-server-per-config (vs batch sweep in same server)
- KV+weight precheck (skip impossible configs)
- CUDA Graph silent fallback detection via log parse
- `--disable-custom-all-reduce` for vLLM (P2P-related hang risk)
- `NCCL_CUMEM_HOST_ENABLE=0` to force /dev/shm path
- per-run watchdog with kill-process-group + GPU poison detect
- structured status taxonomy for offline triage
- `--max-seq-len-to-capture=max_model_len` for fair CG comparison
- `--ignore-eos` for random dataset (deterministic token count)
- SPEC `--noreportable --iterations=1 --copies=168`

Second-round patches applied (post-GPT review of generated scripts):
- `vllm serve` / `vllm bench serve` (replaces deprecated `python -m vllm.entrypoints.*`)
- PGID-based kill via `kill_pgroup` helper (was killing leader PID, not group)
- TP=4 explicit `CUDA_VISIBLE_DEVICES` for both islands (0-3 socket 0, 4-7 socket 1)
- NUMA `cpunodebind` matched to GPU island (was always socket 0)
- Wave-based bench timeout (was naive `600 + batch*30`)
- `oom_precheck.py` handles nested `text_config`/`language_config`

If you find more failure modes during execution, drop notes into
`results/<run>/NOTES.md` and they'll come back through the public repo.
