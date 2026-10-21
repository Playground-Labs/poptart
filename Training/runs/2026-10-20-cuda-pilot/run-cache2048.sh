set -eu
mkdir -p /workspace/poptart
export MLX_CUDA_GRAPH_CACHE_SIZE=2048
cd /workspace/poptart
. /workspace/cleanup-venv/bin/activate
nvidia-smi --query-gpu=timestamp,name,memory.used,utilization.gpu,power.draw --format=csv --loop=1 > /workspace/cleanup-cache2048-gpu-samples.csv &
monitor=$!
trap 'kill "$monitor" 2>/dev/null || true' EXIT
start=$(date +%s)
set +e
sh Training/benchmark_cuda.sh .context/cleanup-model/base .context/cleanup-round8/adapters/0000200_adapters.safetensors /workspace/poptart/probe-cache2048 > /workspace/cleanup-cache2048-console.log 2>&1
result=$?
set -e
end=$(date +%s)
printf '{"exitCode":%s,"wallSeconds":%s}\n' "$result" "$((end-start))" > /workspace/cleanup-cache2048-status.json
cat /workspace/cleanup-cache2048-console.log
if [ "$result" -ne 0 ] && [ -f probe-cache2048/training.log ]; then tail -60 probe-cache2048/training.log; fi
exit "$result"
