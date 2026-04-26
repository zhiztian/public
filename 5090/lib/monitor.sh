#!/bin/bash
# monitor.sh — start/stop GPU monitoring loop in background
# usage:
#   bash monitor.sh start <out_dir>     # writes pidfile to <out_dir>/_monitor.pid
#   bash monitor.sh stop  <out_dir>     # kills monitors and archives logs

set -uo pipefail
ACTION="${1:?action required: start|stop}"
OUT_DIR="${2:?out_dir required}"
PIDFILE="$OUT_DIR/_monitor.pid"

case "$ACTION" in
    start)
        mkdir -p "$OUT_DIR"
        # csv loop: throttle / power / clocks / pcie state — 1Hz
        nvidia-smi --query-gpu=timestamp,index,pstate,clocks.sm,clocks.mem,power.draw,temperature.gpu,utilization.gpu,memory.used,pcie.link.gen.current,pcie.link.width.current --format=csv -l 1 > "$OUT_DIR/nvidia_smi_loop.csv" 2>&1 &
        echo $! >> "$PIDFILE"
        # dmon: per-SM throttle reasons
        nvidia-smi dmon -s pucvmt -d 1 > "$OUT_DIR/nvidia_smi_dmon.csv" 2>&1 &
        echo $! >> "$PIDFILE"
        echo "monitor started: pids=$(cat $PIDFILE | tr '\n' ' ')"
        ;;
    stop)
        if [[ -f "$PIDFILE" ]]; then
            while read -r pid; do
                kill "$pid" 2>/dev/null || true
            done < "$PIDFILE"
            sleep 1
            while read -r pid; do
                kill -9 "$pid" 2>/dev/null || true
            done < "$PIDFILE"
            rm -f "$PIDFILE"
        fi
        echo "monitor stopped"
        ;;
    *)
        echo "usage: $0 start|stop <out_dir>" >&2
        exit 2
        ;;
esac
