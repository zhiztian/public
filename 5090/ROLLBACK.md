# 5090 Bench — Rollback / Recovery Procedures

When a script hangs, OOMs, or leaves GPUs in a bad state.

## 1. Kill all benchmark processes (safe, do this first)

```bash
pkill -9 -f 'vllm.entrypoints|vllm.worker|sglang|torchrun|benchmark_serving|api_server' || true
sleep 5
nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv
```

If the apps list is empty but `nvidia-smi` shows allocated memory → **GPU poison**.

## 2. GPU memory still allocated with no process (poison)

```bash
# Try driver reset per GPU (won't work if anything is mapping it)
nvidia-smi --gpu-reset -i 0
# Repeat 0..7

# If gpu-reset fails: full driver unload
sudo lsof /dev/nvidia*       # confirm nothing using
sudo rmmod nvidia_uvm nvidia_drm nvidia_modeset nvidia
sudo modprobe nvidia
nvidia-smi
```

If rmmod fails because something holds /dev/nvidia*, find it via `lsof`. As last resort, reboot.

## 3. SHM saturation (NCCL silently slow)

```bash
df -h /dev/shm
ls /dev/shm | head
# Clear stale segments left by killed workers
sudo find /dev/shm -name 'nccl-*' -mtime +0 -delete
```

## 4. Server hangs at "capturing CUDA graph" forever (>20 min)

This is a known signature of CUDA Graph capture failure on tinygrad fork
P2P kernels. To recover:

```bash
# 1. kill the server hard
PID=$(cat ~/.cache/5090_bench/.../server.pid)  # or pgrep python
kill -9 -$(ps -o pgid= -p $PID | tr -d ' ')

# 2. cleanup orphans
pkill -9 -f vllm
sleep 10
nvidia-smi

# 3. re-run that single config with --enforce-eager
```

## 5. NCCL hang during AllReduce (no progress, no error)

Already handled in `common.sh:nccl_env` (NCCL_P2P_DISABLE=1). If still hangs:

```bash
# Check that NCCL actually picked SHM, not something else
grep -E 'NCCL INFO|Channel|via' results/<run>/server.log | head -50

# Force SHM-only (no rings via P2P)
export NCCL_P2P_DISABLE=1
export NCCL_SHM_DISABLE=0
export NCCL_NET_DISABLE=1
export NCCL_CUMEM_HOST_ENABLE=0
```

## 6. SPEC CPU 2017 stuck or slow

```bash
# Check if a fprate workload is thrashing memory
top -b -n 1 | head -30
free -h
numastat -m
# If memory exhausted, kill SPEC (graceful first)
pkill -INT runcpu
sleep 30
pkill -9 specinvoke
```

## 7. Disk full from triton/CUDA caches

```bash
du -sh ~/.cache/5090_bench/
# Per-run caches are under results/<run>/cache/{triton,cuda,xdg}
# Safe to delete after a run completes — only affects re-run JIT time
find results -path '*/cache/triton' -type d -exec rm -rf {} +
```

## 8. If all else fails — reboot

Document `dmesg | tail -200` and `nvidia-smi -q` BEFORE rebooting. Save to
`results/_pre_reboot_<date>/` so we can analyze offline.

```bash
mkdir -p results/_pre_reboot_$(date +%Y%m%d_%H%M)
dmesg -T | tail -500 > results/_pre_reboot_*/dmesg.txt
nvidia-smi -q > results/_pre_reboot_*/nvidia_smi_q.txt
ps auxf > results/_pre_reboot_*/ps.txt
sudo reboot
```
