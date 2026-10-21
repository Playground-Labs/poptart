set -eu
mkdir -p /workspace/poptart
tar -xf /workspace/cleanup-runpod-pilot.tar -C /workspace/poptart
cd /workspace/poptart
. /workspace/cleanup-venv/bin/activate
nvidia-smi --query-gpu=timestamp,name,memory.used,utilization.gpu,power.draw --format=csv --loop=1 > /workspace/cleanup-gpu-samples.csv &
monitor=$!
trap 'kill "$monitor" 2>/dev/null || true' EXIT
start=$(date +%s)
set +e
sh Training/benchmark_cuda.sh .context/cleanup-model/base .context/cleanup-round8/adapters/0000200_adapters.safetensors /workspace/poptart/probe-5090 > /workspace/cleanup-probe-console.log 2>&1
result=$?
set -e
end=$(date +%s)
printf '{"exitCode":%s,"wallSeconds":%s}\n' "$result" "$((end-start))" > /workspace/cleanup-probe-status.json
cat /workspace/cleanup-probe-console.log
if [ "$result" -ne 0 ] && [ -f probe-5090/training.log ]; then tail -60 probe-5090/training.log; fi
exit "$result"
