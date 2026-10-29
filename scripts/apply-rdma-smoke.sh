#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
IMAGE=${RDMA_TOOLS_IMAGE:?Set RDMA_TOOLS_IMAGE to the pushed RDMA tools image}
kubectl -n rdma-workloads get namespace >/dev/null
python3 - "$ROOT/k8s/dranet/rdma-smoke.yaml" "$IMAGE" <<'PY' | kubectl apply --dry-run=server -f -
from pathlib import Path
import sys
print(Path(sys.argv[1]).read_text().replace('REPLACE_RDMA_TOOLS_IMAGE', sys.argv[2]), end='')
PY
python3 - "$ROOT/k8s/dranet/rdma-smoke.yaml" "$IMAGE" <<'PY' | kubectl apply -f -
from pathlib import Path
import sys
print(Path(sys.argv[1]).read_text().replace('REPLACE_RDMA_TOOLS_IMAGE', sys.argv[2]), end='')
PY
kubectl -n rdma-workloads wait --for=condition=Ready pod/rdma-smoke-a --timeout=300s
kubectl -n rdma-workloads wait --for=condition=Ready pod/rdma-smoke-b --timeout=300s
for pod in rdma-smoke-a rdma-smoke-b; do
  echo "=== $pod ==="
  kubectl -n rdma-workloads exec "$pod" -- rdma link show
  kubectl -n rdma-workloads exec "$pod" -- ip -4 addr show dev ens800f0np0
done
SERVER_IP=$(kubectl -n rdma-workloads exec rdma-smoke-a -- sh -c "ip -o -4 addr show dev ens800f0np0 | awk '{print \$4}' | cut -d/ -f1")
echo "RDMA server pod address: $SERVER_IP"
echo 'In terminal A run: kubectl -n rdma-workloads exec -it rdma-smoke-a -- ib_write_bw -d mlx5_2'
echo "In terminal B run: kubectl -n rdma-workloads exec -it rdma-smoke-b -- ib_write_bw -d mlx5_2 -F $SERVER_IP"
echo 'Cleanup after testing: kubectl -n rdma-workloads delete -f k8s/dranet/rdma-smoke.yaml'
