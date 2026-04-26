#!/usr/bin/env python3
"""
oom_precheck.py — KV memory + weight estimate, decide SKIP_PRECHECK vs run

Per GPT cross-review §1.1: skip impossible (model, TP, batch, mode) before
wasting an offline cycle. Conservative — false negatives (we ran something
that OOM'd) better than false positives (we skipped something that fit).

usage:
    python3 oom_precheck.py <model_dir> <tp> <batch> <isl_plus_osl> <mode> \
                            [--per-gpu-gb 32] [--quant detect|bf16|mxfp4]

exit 0 = OK to run; exit 10 = skip; exit 20 = bad input
prints JSON to stdout.
"""

import argparse
import json
import os
import sys


def load_config(model_dir):
    cfg_path = os.path.join(model_dir, "config.json")
    if not os.path.isfile(cfg_path):
        print(json.dumps({"error": f"no config.json in {model_dir}"}))
        sys.exit(20)
    with open(cfg_path) as f:
        cfg = json.load(f)
    # Some configs (e.g., gpt-oss multi-modal-style) nest the LM under
    # "text_config" or "language_config". Hoist nested keys but keep
    # outer quantization_config which usually lives at top level.
    for nest_key in ("text_config", "language_config", "llm_config"):
        if isinstance(cfg.get(nest_key), dict):
            for k, v in cfg[nest_key].items():
                cfg.setdefault(k, v)
    return cfg


def cfg_get(cfg, *keys, default=0):
    """Try multiple key spellings (HF/transformers naming drift)."""
    for k in keys:
        if k in cfg and cfg[k] is not None:
            return cfg[k]
    return default


def detect_quant(cfg, override):
    if override and override != "detect":
        return override
    qc = cfg.get("quantization_config") or {}
    quant_method = qc.get("quant_method") or qc.get("quantization") or ""
    if "mxfp4" in quant_method.lower() or "fp4" in quant_method.lower():
        return "mxfp4"
    if "fp8" in quant_method.lower():
        return "fp8"
    if "int8" in quant_method.lower():
        return "int8"
    if "int4" in quant_method.lower() or "gptq" in quant_method.lower() or "awq" in quant_method.lower():
        return "int4"
    # torch_dtype tells us native dtype if no quant
    return cfg.get("torch_dtype", "bfloat16")


def bytes_per_weight(quant):
    return {
        "mxfp4": 0.5,   # 4-bit
        "int4": 0.5,
        "fp8": 1.0,
        "int8": 1.0,
        "bfloat16": 2.0, "float16": 2.0, "bf16": 2.0, "fp16": 2.0,
        "float32": 4.0,
    }.get(quant, 2.0)


def estimate_weight_bytes_per_gpu(cfg, tp, quant):
    n_params = cfg_get(cfg, "num_parameters", "num_params", "n_params", default=0)
    if not n_params:
        h = cfg_get(cfg, "hidden_size", "n_embd", "d_model", default=0)
        L = cfg_get(cfg, "num_hidden_layers", "n_layer", "num_layers", default=0)
        vocab = cfg_get(cfg, "vocab_size", default=0)
        intermediate = cfg_get(cfg, "intermediate_size", "ffn_hidden_size",
                               default=h * 4)
        # transformer block: 4*h*h (attn) + 3*h*intermediate (FFN, gated)
        per_layer = 4 * h * h + 3 * h * intermediate
        n_params = L * per_layer + 2 * h * vocab  # embed + lm_head
    bpw = bytes_per_weight(quant)
    return int(n_params * bpw / max(tp, 1))


def estimate_kv_bytes_per_gpu(cfg, tp, batch, max_seq_len):
    L = cfg_get(cfg, "num_hidden_layers", "n_layer", "num_layers", default=0)
    n_attn = cfg_get(cfg, "num_attention_heads", "n_head", default=1)
    n_kv = cfg_get(cfg, "num_key_value_heads", "n_kv_heads",
                   "num_attention_heads", "n_head", default=n_attn)
    h = cfg_get(cfg, "hidden_size", "n_embd", "d_model", default=0)
    head_dim = cfg_get(cfg, "head_dim", default=0) or (h // max(n_attn, 1))
    # KV per gpu: 2 (K+V) × L × kv_heads_per_gpu × head_dim × bytes × batch × seq_len
    kv_heads_per_gpu = max(n_kv // max(tp, 1), 1)
    bytes_per_elem = 2  # BF16/FP16 KV (FP8 KV cache rare)
    return 2 * L * kv_heads_per_gpu * head_dim * bytes_per_elem * batch * max_seq_len


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("model_dir")
    ap.add_argument("tp", type=int)
    ap.add_argument("batch", type=int)
    ap.add_argument("max_seq_len", type=int)
    ap.add_argument("mode", choices=["eager", "cuda_graph"])
    ap.add_argument("--per-gpu-gb", type=int, default=32)
    ap.add_argument("--quant", default="detect")
    args = ap.parse_args()

    cfg = load_config(args.model_dir)
    quant = detect_quant(cfg, args.quant)
    weight_b = estimate_weight_bytes_per_gpu(cfg, args.tp, quant)
    kv_b = estimate_kv_bytes_per_gpu(cfg, args.tp, args.batch, args.max_seq_len)

    # workspace + activation overhead estimates (empirical, conservative)
    activation_b = 1.5 * 1024**3  # ~1.5 GB framework workspace
    graph_overhead_b = 2.0 * 1024**3 if args.mode == "cuda_graph" else 0.5 * 1024**3
    nccl_buf_b = 0.5 * 1024**3

    total_b = weight_b + kv_b + activation_b + graph_overhead_b + nccl_buf_b

    # usable budget — graph mode keeps less headroom
    util = 0.80 if args.mode == "cuda_graph" else 0.88
    limit_b = int(args.per_gpu_gb * 1024**3 * util)

    decision = "RUN" if total_b <= limit_b else "SKIP_PRECHECK"
    out = {
        "model_dir": args.model_dir,
        "tp": args.tp,
        "batch": args.batch,
        "max_seq_len": args.max_seq_len,
        "mode": args.mode,
        "quant": quant,
        "weight_gb_per_gpu": round(weight_b / 1024**3, 2),
        "kv_gb_per_gpu": round(kv_b / 1024**3, 2),
        "overhead_gb": round((activation_b + graph_overhead_b + nccl_buf_b) / 1024**3, 2),
        "estimated_total_gb_per_gpu": round(total_b / 1024**3, 2),
        "limit_gb_per_gpu": round(limit_b / 1024**3, 2),
        "decision": decision,
    }
    print(json.dumps(out, indent=2))
    sys.exit(0 if decision == "RUN" else 10)


if __name__ == "__main__":
    main()
