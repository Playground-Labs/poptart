set -eu
mkdir -p /workspace/poptart
export MLX_USE_CUDA_GRAPHS=0
cd /workspace/poptart
. /workspace/cleanup-venv/bin/activate
nvidia-smi --query-gpu=timestamp,name,memory.used,utilization.gpu,power.draw --format=csv --loop=1 > /workspace/cleanup-no-graphs-gpu-samples.csv &
monitor=$!
trap 'kill "$monitor" 2>/dev/null || true' EXIT
start=$(date +%s)
set +e
sh Training/benchmark_cuda.sh .context/cleanup-model/base .context/cleanup-round8/adapters/0000200_adapters.safetensors /workspace/poptart/probe-no-graphs > /workspace/cleanup-no-graphs-console.log 2>&1
result=$?
set -e
end=$(date +%s)
printf '{"exitCode":%s,"wallSeconds":%s}\n' "$result" "$((end-start))" > /workspace/cleanup-no-graphs-status.json
cat /workspace/cleanup-no-graphs-console.log
if [ "$result" -ne 0 ] && [ -f probe-no-graphs/training.log ]; then tail -60 probe-no-graphs/training.log; fi
exit "$result"
