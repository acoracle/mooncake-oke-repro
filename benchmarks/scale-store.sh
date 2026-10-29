#!/usr/bin/env bash
# Launch independent native store_kv_bench clients across the first N ready owners.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
NS=${NS:-mooncake}
IMAGE=${IMAGE:?Set IMAGE to the pushed Mooncake Store image}
OWNERS=${OWNERS:-2}
CLIENTS_PER_OWNER=${CLIENTS_PER_OWNER:-8}
PROTOCOL=${PROTOCOL:-rdma}
DEVICE_NAME=${DEVICE_NAME:-mlx5_2}
DURATION=${DURATION:-30}
OBJECTS=${OBJECTS:-4096}
VALUE_SIZE=${VALUE_SIZE:-1048576}
BATCH_SIZE=${BATCH_SIZE:-16}
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$RANDOM"
RESULTS=${RESULTS:-"$ROOT/benchmarks/results-$RUN_ID"}
mkdir -p "$RESULTS"
command -v python3 >/dev/null
kubectl -n "$NS" get deployment mooncake-master >/dev/null
kubectl -n "$NS" rollout status daemonset/mooncake-storage --timeout=300s
if kubectl -n "$NS" get pods -l app=mooncake-benchmark-client -o name | grep -q .; then
  echo "Benchmark client pods from an earlier run remain. Save results, then delete them before rerunning." >&2
  exit 1
fi
OWNER_NODES=$(kubectl -n "$NS" get pods -l app=mooncake-storage -o json | python3 -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps(sorted({p["spec"]["nodeName"] for p in d["items"] if p.get("status",{}).get("phase")=="Running"})))')
ACTUAL_OWNERS=$(python3 -c 'import json,sys; print(len(json.loads(sys.argv[1])))' "$OWNER_NODES")
if [[ "$ACTUAL_OWNERS" != "$OWNERS" ]]; then
  echo "Requested OWNERS=$OWNERS but found $ACTUAL_OWNERS running owner nodes. Resize the pool or change OWNERS; this script does not alter OCI resources." >&2
  exit 1
fi
python3 "$ROOT/benchmarks/render-client-pods.py" --nodes-json "$OWNER_NODES" \
  --owners "$OWNERS" --clients-per-owner "$CLIENTS_PER_OWNER" --image "$IMAGE" \
  --namespace "$NS" --protocol "$PROTOCOL" > "$RESULTS/clients.yaml"
kubectl apply --dry-run=server -f "$RESULTS/clients.yaml"
kubectl apply -f "$RESULTS/clients.yaml"
CLIENTS=$((OWNERS * CLIENTS_PER_OWNER))
for ((i=0; i<CLIENTS; i++)); do
  kubectl -n "$NS" wait --for=condition=Ready "pod/mcbench-$(printf '%03d' "$i")" --timeout=300s
done

run_client() {
  local i=$1 pod port prefix
  pod="mcbench-$(printf '%03d' "$i")"
  port=$((50071 + i))
  prefix="${RUN_ID}-${i}"
  kubectl -n "$NS" exec "$pod" -- env \
    NS="$NS" PROTOCOL="$PROTOCOL" DEVICE_NAME="$DEVICE_NAME" \
    BATCH_SIZE="$BATCH_SIZE" OBJECTS="$OBJECTS" VALUE_SIZE="$VALUE_SIZE" \
    DURATION="$DURATION" CLIENT_PORT="$port" KEY_PREFIX="$prefix" bash -ec '
    set -euo pipefail
    export PYTHONPATH=/opt/Mooncake/build-store/mooncake-integration
    export MOONCAKE_STORE_MODULE=_store
    LIB_DIRS=$(find /opt/Mooncake/build-store -name "*.so*" -printf "%h\n" | sort -u | paste -sd: -)
    export LD_LIBRARY_PATH="$LIB_DIRS:/usr/local/lib:${LD_LIBRARY_PATH:-}"
    if [[ "$PROTOCOL" == rdma ]]; then ulimit -l unlimited; fi
    exec python3 /opt/Mooncake/mooncake-store/benchmarks/store_kv_bench.py \
      --scenario=read_perf --io-api=zcopy --numjobs=1 --iodepth=1 \
      --batch-size="$BATCH_SIZE" --nr-objects="$OBJECTS" --prepare-objects="$OBJECTS" \
      --value-size="$VALUE_SIZE" --runtime="$DURATION" --memory-replica-num=1 \
      --nof-replica-num=0 --dfs-replica-num=0 --global-segment-size=0 \
      --local-buffer-size=268435456 --master-server="mooncake-master.${NS}.svc.cluster.local:50051" \
      --metadata-server="http://mooncake-master.${NS}.svc.cluster.local:8080/metadata" \
      --local-hostname="${POD_IP}:${CLIENT_PORT}" --protocol="$PROTOCOL" \
      --device-name="$DEVICE_NAME" --key-size=64 --key-prefix="$KEY_PREFIX" \
      --latency-sample-rate=1 --summary-json=/tmp/summary.json \
      2>&1 | tee /tmp/benchmark.log
  ' > "$RESULTS/$pod.log" 2>&1
  kubectl -n "$NS" exec "$pod" -- cat /tmp/summary.json > "$RESULTS/$pod.json"
}

pids=()
for ((i=0; i<CLIENTS; i++)); do run_client "$i" & pids+=("$!"); done
client_status=0
for pid in "${pids[@]}"; do wait "$pid" || client_status=1; done
if (( client_status != 0 )); then
  echo "At least one benchmark client failed; inspect $RESULTS/*.log" >&2
  exit 1
fi
python3 - "$RESULTS" <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
total = 0.0
bad = False
for f in sorted(root.glob('mcbench-*.json')):
    doc = json.loads(f.read_text())
    phases = doc.get('phases', {})
    r = phases.get('read_perf', {})
    rate = float(r.get('MiB_per_sec', 0))
    total += rate
    failures = int(r.get('failed_kvs', 0))
    misses = int(r.get('misses', 0))
    verify = int(r.get('verify_failures', 0))
    bad |= bool(failures or misses or verify)
    print(f'{f.stem}: {rate:.1f} MiB/s; failed={failures}; misses={misses}; verify_failures={verify}')
print(f'AGGREGATE read throughput: {total:.1f} MiB/s')
if bad:
    raise SystemExit('Errors were reported; treat throughput as non-passing and inspect per-client logs.')
PY
printf 'Results: %s\n' "$RESULTS"
printf 'Cleanup after saving results: kubectl -n %s delete pods -l app=mooncake-benchmark-client\n' "$NS"
