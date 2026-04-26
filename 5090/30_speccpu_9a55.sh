#!/bin/bash
# 30_speccpu_9a55.sh — SPEC CPU 2017 intrate+fprate ref on 9A55
# Per GPT cross-review §4: budget 18-32 hours total for AOCC + GCC15.1.
# 1 iteration, copies=168 (168 physical cores on 2P 9A55).
# Non-reportable mode (--noreportable + iterations=1).
#
# PREREQUISITES:
#   - SPEC CPU 2017 installed at $SPEC_HOME (default /home/zz/speccpu2017)
#   - AOCC 5.0 at /opt/AMD/aocc-compiler-5.0.0/setenv_AOCC.sh
#   - GCC 15.1 at /opt/gcc-15.1/bin/gcc (or modify GCC_BIN)
#   - SPEC config files (myaocc.cfg, mygcc15.cfg) — TEMPLATE included below
#
# Run preferably overnight; SPEC fprate doesn't tolerate concurrent GPU load.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

OUT="$RESULTS_ROOT/30_speccpu_9a55"
mkdir -p "$OUT"

SPEC_HOME="${SPEC_HOME:-$HOME/speccpu2017}"
COPIES="${COPIES:-168}"
AOCC_CFG_NAME="aocc500_9a55"
GCC_CFG_NAME="gcc151_9a55"

[[ -f "$SPEC_HOME/shrc" ]] || die "SPEC CPU 2017 not found at $SPEC_HOME (set SPEC_HOME=...)"

# global system snapshot — captures dmidecode, lscpu, BIOS-relevant
log "==> system snapshot"
bash "$SCRIPT_DIR/lib/snapshot.sh" "$OUT/snapshot" global

# safety: make sure no GPU work is running (SPEC fprate murders GPU NUMA)
if pgrep -f 'vllm|sglang|nccl-tests' > /dev/null; then
    die "GPU benchmarks still running — kill them before SPEC fprate"
fi

# resource limits
ulimit -s unlimited 2>/dev/null || true
ulimit -n 1048576 2>/dev/null || true

# verify SMT topology — copies=168 should land on physical cores
log "==> CPU topology check"
{
    echo "lscpu summary:"
    lscpu | grep -E 'Socket|Core|Thread|CPU\('
    echo
    echo "physical cores: $(lscpu -e=CORE,SOCKET | tail -n +2 | sort -u | wc -l)"
    echo "logical CPUs:   $(nproc)"
    echo
    if [[ $(nproc) -ne $((COPIES * 2)) && $(nproc) -ne $COPIES ]]; then
        echo "WARN: nproc=$(nproc) doesn't match copies=$COPIES × {1,2}; verify SMT setting"
    fi
} > "$OUT/topology.txt"

# write SPEC config templates (user can tune; these are minimum-viable)
cat > "$OUT/${AOCC_CFG_NAME}.cfg" <<EOF
# AOCC 5.0 config for 9A55 SPEC CPU 2017 rate
%define aocc_root /opt/AMD/aocc-compiler-5.0.0
preenv = 1
strict_rundir_verify = 0
makeflags = -j16
output_format = txt,csv,html

%ifdef %{label}
default:
   label = ${AOCC_CFG_NAME}
%endif

default:
   CC  = \$(aocc_root)/bin/clang
   CXX = \$(aocc_root)/bin/clang++
   FC  = \$(aocc_root)/bin/flang
   COPTIMIZE   = -O3 -march=znver5 -flto -mllvm -unroll-aggressive
   CXXOPTIMIZE = -O3 -march=znver5 -flto
   FOPTIMIZE   = -O3 -march=znver5 -flto

intrate,fprate:
   copies = ${COPIES}

# Required since 1.1.x:
intrate:
   PORTABILITY     = -DSPEC_LP64
   500.perlbench_r = PORTABILITY = -DSPEC_LP64 -DSPEC_LINUX_X64
   502.gcc_r       = CPORTABILITY = -fno-strict-aliasing -fcommon -fno-stack-protector
   523.xalancbmk_r = CXXPORTABILITY = -DSPEC_LINUX
   525.x264_r      = PORTABILITY = -fcommon

fprate:
   PORTABILITY     = -DSPEC_LP64
   503.bwaves_r    = FPORTABILITY = -fconvert=big-endian
   521.wrf_r       = CPORTABILITY = -DSPEC_CASE_FLAG -fcommon
                     FPORTABILITY = -fconvert=big-endian
   527.cam4_r      = PORTABILITY = -fcommon
   549.fotonik3d_r = FPORTABILITY = -fconvert=big-endian
   554.roms_r      = FPORTABILITY = -fconvert=big-endian

%define model -m64
EOF

cat > "$OUT/${GCC_CFG_NAME}.cfg" <<EOF
# GCC 15.1 config for 9A55 SPEC CPU 2017 rate
%define gcc_root /opt/gcc-15.1
preenv = 1
strict_rundir_verify = 0
makeflags = -j16
output_format = txt,csv,html

default:
   label = ${GCC_CFG_NAME}
   CC  = \$(gcc_root)/bin/gcc
   CXX = \$(gcc_root)/bin/g++
   FC  = \$(gcc_root)/bin/gfortran
   COPTIMIZE   = -O3 -march=znver5 -flto -funroll-loops
   CXXOPTIMIZE = -O3 -march=znver5 -flto -funroll-loops
   FOPTIMIZE   = -O3 -march=znver5 -flto -funroll-loops

intrate,fprate:
   copies = ${COPIES}

intrate:
   PORTABILITY     = -DSPEC_LP64
   500.perlbench_r = PORTABILITY = -DSPEC_LP64 -DSPEC_LINUX_X64
   502.gcc_r       = CPORTABILITY = -fno-strict-aliasing -fcommon -fno-stack-protector
   523.xalancbmk_r = CXXPORTABILITY = -DSPEC_LINUX
   525.x264_r      = PORTABILITY = -fcommon

fprate:
   PORTABILITY     = -DSPEC_LP64
   503.bwaves_r    = FPORTABILITY = -fconvert=big-endian
   521.wrf_r       = CPORTABILITY = -DSPEC_CASE_FLAG -fcommon
                     FPORTABILITY = -fconvert=big-endian
   527.cam4_r      = PORTABILITY = -fcommon
   549.fotonik3d_r = FPORTABILITY = -fconvert=big-endian
   554.roms_r      = FPORTABILITY = -fconvert=big-endian
EOF

# install configs
cp "$OUT/${AOCC_CFG_NAME}.cfg" "$SPEC_HOME/config/"
cp "$OUT/${GCC_CFG_NAME}.cfg" "$SPEC_HOME/config/"

run_spec() {
    local cfg_label="$1" setup_cmd="$2"
    local sub_out="$OUT/$cfg_label"
    mkdir -p "$sub_out"
    log "==> SPEC $cfg_label start at $(ts)"

    # source SPEC env + compiler env in subshell
    (
        cd "$SPEC_HOME"
        source ./shrc
        eval "$setup_cmd"
        runcpu --version > "$sub_out/runcpu_version.txt" 2>&1
        runcpu --config="$cfg_label" --action=clobber intrate fprate > "$sub_out/clobber.log" 2>&1 || true
        runcpu --config="$cfg_label" \
               --size=ref --tune=base --iterations=1 --copies=$COPIES \
               --noreportable \
               intrate fprate \
               > "$sub_out/runcpu.log" 2>&1
    )
    local rc=$?
    log "SPEC $cfg_label rc=$rc finished at $(ts)"

    # archive results
    local result_dir="$SPEC_HOME/result"
    [[ -d "$result_dir" ]] && tar czf "$sub_out/result_archive.tgz" -C "$SPEC_HOME" result/
    cp "$result_dir"/CPU2017.*.txt "$sub_out/" 2>/dev/null || true
    cp "$result_dir"/CPU2017.*.csv "$sub_out/" 2>/dev/null || true
    cp "$result_dir"/CPU2017.*.html "$sub_out/" 2>/dev/null || true

    if (( rc == 0 )); then
        emit_status "$sub_out" "PASS" "SPEC $cfg_label completed"
    else
        emit_status "$sub_out" "UNKNOWN_FAIL" "SPEC $cfg_label rc=$rc — see runcpu.log"
    fi
    return $rc
}

# --- AOCC ---
AOCC_SETUP="source /opt/AMD/aocc-compiler-5.0.0/setenv_AOCC.sh"
run_spec "$AOCC_CFG_NAME" "$AOCC_SETUP" || log "WARN: AOCC SPEC failed; continuing to GCC"

# --- GCC 15.1 ---
GCC_SETUP="export PATH=/opt/gcc-15.1/bin:\$PATH; export LD_LIBRARY_PATH=/opt/gcc-15.1/lib64:\$LD_LIBRARY_PATH"
run_spec "$GCC_CFG_NAME" "$GCC_SETUP" || log "WARN: GCC SPEC failed"

emit_status "$OUT" "PASS" "SPEC runs done (per-cfg status in subdirs)"
log "==> SPEC complete. Artifacts in $OUT"
