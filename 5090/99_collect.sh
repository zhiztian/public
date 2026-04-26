#!/bin/bash
# 99_collect.sh — pack results/ into tar.gz, generate summary index, ready for git push
# Run after benchmarks complete; produces results_<date>.tgz at public/5090/

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

DATE=$(date +%Y%m%d_%H%M)
TGZ="$SCRIPT_DIR/results_${DATE}.tgz"
INDEX="$SCRIPT_DIR/results_${DATE}_index.json"

# build summary index from all status.json
log "==> building results index"
python3 - > "$INDEX" <<PY
import os, json, glob
root = "$RESULTS_ROOT"
out = {"timestamp": "$DATE", "runs": []}
for sf in sorted(glob.glob(os.path.join(root, "**", "status.json"), recursive=True)):
    try:
        with open(sf) as f:
            s = json.load(f)
    except Exception as e:
        s = {"status": "PARSE_FAIL", "reason": str(e)}
    rel = os.path.relpath(os.path.dirname(sf), root)
    rec = {"path": rel, **s}
    # try to attach result.json key metrics
    rj = os.path.join(os.path.dirname(sf), "result.json")
    if os.path.isfile(rj):
        try:
            with open(rj) as f:
                d = json.load(f)
            rec["metrics"] = {
                k: d.get(k) for k in
                ("output_throughput","total_token_throughput","mean_ttft_ms",
                 "mean_tpot_ms","p99_ttft_ms","p99_tpot_ms","request_throughput",
                 "completed","mean_itl_ms")
                if k in d
            }
        except Exception:
            pass
    out["runs"].append(rec)
print(json.dumps(out, indent=2))
PY

log "==> packing tarball"
# exclude HF cache dirs and triton compile artifacts (huge, regenerable)
tar --exclude='cache/triton' --exclude='cache/cuda' --exclude='cache/xdg' \
    --exclude='*.safetensors' \
    -czf "$TGZ" -C "$SCRIPT_DIR" results

ls -lh "$TGZ" "$INDEX"
log "==> done. To push:"
log "  cd $SCRIPT_DIR/.. && git add 5090/results_${DATE}.tgz 5090/results_${DATE}_index.json"
log "  git commit -m '5090 bench results $DATE'"
log "  git push"
