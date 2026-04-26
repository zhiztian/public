#!/bin/bash
# 00_env_audit.sh — software stack preflight + diagnostic dump
# RUN FIRST. Captures everything we need to triage offline.
#
# Output: results/00_env_audit/
#   identity.txt, nvidia_smi*.txt, lspci_acs_links.txt, dmesg_relevant.txt,
#   python_stack.txt, vllm_help.txt, sglang_help.txt, attention_probe.json
#
# Exit nonzero if a critical preflight fails (driver missing, no GPUs, etc.)

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

OUT="$RESULTS_ROOT/00_env_audit"
mkdir -p "$OUT"

# 第一道闸：runtime 必须就位（conda env 激活，torch+vllm 可 import）
# 否则后面所有 probe 都是 bash 错误堆，PASS 也是误报
require_runtime

log "==> snapshot (global scope)"
bash "$SCRIPT_DIR/lib/snapshot.sh" "$OUT" global

log "==> vllm/sglang help dump (full surface — used to triage flag drift)"
if [[ -n "$VLLM_BIN" ]]; then
    "$VLLM_BIN" --version > "$OUT/vllm_version.txt" 2>&1 || true
    "$VLLM_BIN" serve --help > "$OUT/vllm_serve_help.txt" 2>&1 || \
        echo "vllm serve --help failed: $?" > "$OUT/vllm_serve_help.txt"
    "$VLLM_BIN" bench serve --help > "$OUT/vllm_bench_help.txt" 2>&1 || \
        echo "vllm bench serve --help failed: $?" > "$OUT/vllm_bench_help.txt"
else
    echo "vllm CLI not on PATH" > "$OUT/vllm_serve_help.txt"
fi
$PYTHON_BIN -m sglang.launch_server --help > "$OUT/sglang_help.txt" 2>&1 || \
    echo "sglang not importable — $?" > "$OUT/sglang_help.txt"

log "==> attention backend probe (per GPT §1.6)"
$PYTHON_BIN - > "$OUT/attention_probe.json" 2>&1 <<'PY'
import json, traceback
out = {}

def probe(name, fn):
    try:
        fn()
        out[name] = {"status": "ok"}
    except Exception as e:
        out[name] = {"status": "fail", "error": f"{type(e).__name__}: {e}"}

def t_torch():
    import torch
    x = torch.randn(1024, 1024, dtype=torch.bfloat16, device="cuda")
    y = x @ x.T
    torch.cuda.synchronize()
    return y.shape

def t_sdpa():
    import torch
    import torch.nn.functional as F
    q = torch.randn(2, 8, 128, 64, dtype=torch.bfloat16, device="cuda")
    k = torch.randn(2, 8, 128, 64, dtype=torch.bfloat16, device="cuda")
    v = torch.randn(2, 8, 128, 64, dtype=torch.bfloat16, device="cuda")
    o = F.scaled_dot_product_attention(q, k, v)
    torch.cuda.synchronize()
    return o.shape

def t_flash_attn():
    import torch
    from flash_attn import flash_attn_func
    q = torch.randn(2, 128, 8, 64, dtype=torch.bfloat16, device="cuda")
    k = torch.randn(2, 128, 8, 64, dtype=torch.bfloat16, device="cuda")
    v = torch.randn(2, 128, 8, 64, dtype=torch.bfloat16, device="cuda")
    o = flash_attn_func(q, k, v)
    torch.cuda.synchronize()
    return o.shape

def t_flashinfer():
    import flashinfer
    return flashinfer.__version__

def t_triton():
    import triton, triton.language as tl
    @triton.jit
    def _k(p, BLOCK: tl.constexpr):
        i = tl.program_id(0)
        tl.store(p + i, i)
    import torch
    buf = torch.zeros(64, dtype=torch.int32, device="cuda")
    _k[(64,)](buf, 64)
    torch.cuda.synchronize()
    return buf.sum().item()

probe("torch_matmul_bf16", t_torch)
probe("sdpa_native", t_sdpa)
probe("flash_attn", t_flash_attn)
probe("flashinfer_import", t_flashinfer)
probe("triton_kernel", t_triton)

print(json.dumps(out, indent=2))
PY

log "==> NCCL minimal probe (TP=2 echo, NCCL_P2P_DISABLE=1)"
nccl_env
$PYTHON_BIN - > "$OUT/nccl_probe.txt" 2>&1 <<'PY'
import os, torch, torch.distributed as dist
import torch.multiprocessing as mp

def worker(rank, world):
    os.environ["MASTER_ADDR"] = "127.0.0.1"
    os.environ["MASTER_PORT"] = "29501"
    dist.init_process_group("nccl", rank=rank, world_size=world)
    torch.cuda.set_device(rank)
    t = torch.tensor([float(rank + 1)], device="cuda")
    dist.all_reduce(t)
    print(f"rank{rank}: all_reduce={t.item()} (expected 3.0 for world=2)")
    dist.destroy_process_group()

if __name__ == "__main__":
    if torch.cuda.device_count() < 2:
        print("only 1 GPU visible, skipping NCCL probe")
    else:
        mp.spawn(worker, nprocs=2, args=(2,))
PY

# critical preflight checks
log "==> critical checks"
fail=0
if ! command -v nvidia-smi > /dev/null; then log "FAIL: nvidia-smi missing"; fail=1; fi
if ! nvidia-smi -L | grep -q "GPU 0"; then log "FAIL: no GPUs visible"; fail=1; fi
# attention probe 必须有任意 backend ok（否则后续 vLLM 一定起不来）
if ! grep -q '"status": "ok"' "$OUT/attention_probe.json"; then
    log "FAIL: 0 attention backend passed probe — see $OUT/attention_probe.json"
    fail=1
fi
# NCCL probe 必须没有 bash 错误（说明 PYTHON_BIN 解析正常）
if grep -qE 'command not found|No such file' "$OUT/nccl_probe.txt" 2>/dev/null; then
    log "FAIL: nccl_probe 出现 shell 错误，PYTHON_BIN 可能为空 — see $OUT/nccl_probe.txt"
    fail=1
fi
# vllm/sglang help 必须真有内容（>5 行说明真打印了 help）
for h in "$OUT/vllm_serve_help.txt" "$OUT/sglang_help.txt"; do
    if [[ ! -s "$h" ]] || (( $(wc -l < "$h") < 5 )); then
        log "WARN: $(basename "$h") 内容异常短（<5 行）"
    fi
done

# /dev/shm sanity (NCCL SHM path needs it)
shm_kb=$(df -k /dev/shm | awk 'NR==2 {print $4}')
shm_gb=$(( shm_kb / 1024 / 1024 ))
log "/dev/shm free: ${shm_gb} GB"
if (( shm_gb < 16 )); then log "WARN: /dev/shm < 16GB, NCCL SHM path may suffer"; fi

if (( fail )); then
    emit_status "$OUT" "BACKEND_UNSUPPORTED" "critical preflight failed; see logs"
    exit 1
fi

emit_status "$OUT" "PASS" "env audit completed"
log "==> done. artifacts in $OUT"
