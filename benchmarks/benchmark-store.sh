#!/usr/bin/env bash
# Run on the operator/bastion with kubectl access. Uses the previously built image.
set -euo pipefail
NS=${NS:-mooncake}
POD=${POD:-mooncake-bench}
IMAGE=${IMAGE:?Set IMAGE to the Mooncake Store image pushed to OCIR}
PROTOCOL=${PROTOCOL:-tcp}
DEVICE_NAME=${DEVICE_NAME:-mlx5_2}
RUN_ID="mc$(date +%s)"
RESULTS=${RESULTS:-"mooncake-results-$RUN_ID"}
mkdir -p "$RESULTS"
command -v python3 >/dev/null
kubectl -n "$NS" get deployment mooncake-master
kubectl -n "$NS" get daemonset mooncake-storage
if kubectl -n "$NS" get pod "$POD" >/dev/null 2>&1; then
  echo "Pod $NS/$POD already exists. Set POD to a new name to avoid changing it." >&2
  exit 1
fi

if [[ "$PROTOCOL" == rdma ]]; then RDMA_PRIVILEGED=true; else RDMA_PRIVILEGED=false; fi
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: $POD
  namespace: $NS
spec:
  restartPolicy: Never
  imagePullSecrets:
    - name: ocir-pull
  hostNetwork: true
  dnsPolicy: ClusterFirstWithHostNet
  nodeSelector:
    node.kubernetes.io/instance-type: BM.Optimized3.36
  containers:
    - name: benchmark
      image: $IMAGE
      command: ["/bin/bash", "-c", "sleep infinity"]
      env:
        - name: POD_IP
          valueFrom:
            fieldRef:
              fieldPath: status.podIP
        - name: MC_TCP_BIND_ADDRESS
          valueFrom:
            fieldRef:
              fieldPath: status.podIP
        - name: MC_IB_TC
          value: "41"
      securityContext:
        privileged: ${RDMA_PRIVILEGED:-false}
      volumeMounts:
        - name: infiniband
          mountPath: /dev/infiniband
      resources:
        requests:
          cpu: "2"
          memory: 4Gi
        limits:
          memory: 16Gi
  volumes:
    - name: infiniband
      hostPath:
        path: /dev/infiniband
        type: Directory
EOF
kubectl -n "$NS" wait --for=condition=Ready "pod/$POD" --timeout=300s
echo 'Building the Python Store binding in the benchmark pod; this may take several minutes.'
kubectl -n "$NS" exec "$POD" -- \
  cmake --build /opt/Mooncake/build-store --target store --parallel 1

kubectl -n "$NS" exec -i "$POD" -- bash -c 'cat > /tmp/run-store-bench; chmod 755 /tmp/run-store-bench' <<'WRAPPER'
#!/usr/bin/env bash
set -euo pipefail
export PYTHONPATH=/opt/Mooncake/build-store/mooncake-integration
export MOONCAKE_STORE_MODULE=_store
LIB_DIRS=$(find /opt/Mooncake/build-store -name '*.so*' -printf '%h\n' | sort -u | paste -sd: -)
export LD_LIBRARY_PATH="$LIB_DIRS:/usr/local/lib:${LD_LIBRARY_PATH:-}"
if [[ "$BENCH_PROTOCOL" == rdma ]]; then ulimit -l unlimited; fi
exec python3 /opt/Mooncake/mooncake-store/benchmarks/store_kv_bench.py \
  --master-server="mooncake-master.${BENCH_NAMESPACE}.svc.cluster.local:50051" \
  --metadata-server="http://mooncake-master.${BENCH_NAMESPACE}.svc.cluster.local:8080/metadata" \
  --local-hostname="${POD_IP}:50071" \
  --protocol="$BENCH_PROTOCOL" --device-name="$BENCH_DEVICE" --global-segment-size=0 --local-buffer-size=268435456 \
  --key-size=64 --memory-replica-num=1 \
  --latency-sample-rate=1 --journal=failures "$@"
WRAPPER

bench() {
  local name=$1
  shift
  echo "Running $name..."
  kubectl -n "$NS" exec "$POD" -- env "BENCH_NAMESPACE=$NS" "BENCH_PROTOCOL=$PROTOCOL" "BENCH_DEVICE=$DEVICE_NAME" \
    /tmp/run-store-bench --summary-json="/tmp/$name.json" \
    --key-prefix="$RUN_ID-$name" "$@" 2>&1 | tee "$RESULTS/$name.log"
  kubectl -n "$NS" exec "$POD" -- cat "/tmp/$name.json" > "$RESULTS/$name.json"
  python3 - "$RESULTS/$name.json" <<'PY'
import json, sys
result = json.load(open(sys.argv[1]))
bad = False
for name, s in result['phases'].items():
    print(f"{name}: {s['MiB_per_sec']:.1f} MiB/s, {s['kv_per_sec']:.0f} objects/s, "
          f"batch p50/p95/p99={s['lat_p50_ms']:.3f}/{s['lat_p95_ms']:.3f}/{s['lat_p99_ms']:.3f} ms, "
          f"failed={s['failed_kvs']}, misses={s['misses']}, verify_failures={s['verify_failures']}")
    bad |= any(s[k] for k in ('failed_kvs', 'misses', 'verify_failures'))
if bad:
    sys.exit('Benchmark reported errors; inspect the log before interpreting throughput.')
PY
}

# Correctness: write/read and validate 256 MiB, including payload contents.
bench verify --scenario=verify_write --io-api=plain \
  --nr-objects=256 --value-size=1048576 --batch-size=1 \
  --numjobs=1 --iodepth=1 --verify --pattern=mooncake

# Write a fixed 16 GiB dataset. This ends at 16 GiB, rather than after 30 seconds.
bench write4 --scenario=write_perf --io-api=zcopy \
  --nr-objects=16384 --value-size=1048576 --batch-size=16 \
  --numjobs=4 --iodepth=1

# Each read test first prepares its own 4 GiB dataset, then reads it for 30 seconds.
for jobs in 1 4; do
  bench "read$jobs" --scenario=read_perf --io-api=zcopy \
    --nr-objects=4096 --value-size=1048576 --batch-size=16 \
    --numjobs="$jobs" --iodepth=1 --runtime=30
done

echo "Results saved in $RESULTS"
echo "Benchmark pod retained for inspection: kubectl -n $NS delete pod $POD"
echo 'Test keys remain in the cache under a unique prefix until evicted.'
