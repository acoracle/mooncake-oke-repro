#!/usr/bin/env bash
# Run an owner-count sweep on a fixed worker pool by temporarily selecting a subset
# of Mooncake storage nodes. This script never calls OCI or changes node-pool size.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
NS=${NS:-mooncake}
IMAGE=${IMAGE:?Set IMAGE to the full Mooncake Store image reference}
OWNERS_SWEEP=${OWNERS_SWEEP:-"1 2 3"}
CLIENTS_PER_OWNER=${CLIENTS_PER_OWNER:-2}
PROTOCOL=${PROTOCOL:-rdma}
DEVICE_NAME=${DEVICE_NAME:-mlx5_2}

command -v kubectl >/dev/null
command -v python3 >/dev/null
kubectl -n "$NS" get deployment mooncake-master >/dev/null
kubectl -n "$NS" get daemonset mooncake-storage >/dev/null

read -r -a OWNER_COUNTS <<< "$OWNERS_SWEEP"
if ((${#OWNER_COUNTS[@]} == 0)); then
  echo "OWNERS_SWEEP must contain one or more owner counts, such as '1 2 3'." >&2
  exit 2
fi
for count in "${OWNER_COUNTS[@]}"; do
  if [[ ! "$count" =~ ^[1-9][0-9]*$ ]]; then
    echo "Invalid owner count: $count" >&2
    exit 2
  fi
done
if [[ ! "$CLIENTS_PER_OWNER" =~ ^[1-9][0-9]*$ ]]; then
  echo "CLIENTS_PER_OWNER must be a positive integer." >&2
  exit 2
fi

TMP_DIR=$(mktemp -d)
ORIGINAL_SELECTOR="$TMP_DIR/original-node-selector.json"
PATCH_FILE="$TMP_DIR/node-selector-patch.json"
INVENTORY="$TMP_DIR/nodes.json"
kubectl -n "$NS" get daemonset mooncake-storage -o json \
  | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["spec"]["template"]["spec"].get("nodeSelector", {})))' \
  > "$ORIGINAL_SELECTOR"
python3 - "$ORIGINAL_SELECTOR" <<'PY'
import json, sys
selector = json.load(open(sys.argv[1]))
if "bench.mooncake/owner" in selector:
    raise SystemExit("The DaemonSet already uses bench.mooncake/owner; remove that selector before running this script.")
PY

kubectl get nodes -o json > "$INVENTORY"
python3 - "$INVENTORY" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
if any("bench.mooncake/owner" in n.get("metadata", {}).get("labels", {}) for n in doc["items"]):
    raise SystemExit("At least one node already has bench.mooncake/owner; choose a different temporary label or remove it first.")
PY
mapfile -t ELIGIBLE_NODES < <(python3 - "$INVENTORY" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
for node in sorted(doc["items"], key=lambda n: n["metadata"]["name"]):
    labels = node["metadata"].get("labels", {})
    if (labels.get("node.kubernetes.io/instance-type") == "BM.Optimized3.36"
            and labels.get("oci-rdma") == "true"):
        print(node["metadata"]["name"])
PY
)
mapfile -t READY_NODES < <(python3 - "$INVENTORY" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
for node in sorted(doc["items"], key=lambda n: n["metadata"]["name"]):
    labels = node["metadata"].get("labels", {})
    ready = any(c.get("type") == "Ready" and c.get("status") == "True"
                for c in node.get("status", {}).get("conditions", []))
    if (ready and labels.get("node.kubernetes.io/instance-type") == "BM.Optimized3.36"
            and labels.get("oci-rdma") == "true"):
        print(node["metadata"]["name"])
PY
)

for count in "${OWNER_COUNTS[@]}"; do
  if ((count > ${#READY_NODES[@]})); then
    echo "Requested $count owners, but only ${#READY_NODES[@]} eligible Ready RDMA workers exist." >&2
    exit 1
  fi
done
if kubectl -n "$NS" get pods -l app=mooncake-benchmark-client -o name | grep -q .; then
  echo "Benchmark client pods already exist; save their results and remove them before starting." >&2
  exit 1
fi

selector_patched=0
restore() {
  local status=$?
  local restore_status=0
  local selector_restored=0
  trap - EXIT INT TERM
  set +e
  kubectl -n "$NS" delete pods -l app=mooncake-benchmark-client --ignore-not-found --wait=true >/dev/null 2>&1
  if ((selector_patched)); then
    python3 - "$ORIGINAL_SELECTOR" "$PATCH_FILE" <<'PY'
import json, sys
selector = json.load(open(sys.argv[1]))
patch = [{"op": "replace", "path": "/spec/template/spec/nodeSelector", "value": selector}]
with open(sys.argv[2], "w") as f:
    json.dump(patch, f)
PY
    if kubectl -n "$NS" patch daemonset mooncake-storage --type=json --patch-file="$PATCH_FILE"; then
      selector_restored=1
      kubectl -n "$NS" rollout status daemonset/mooncake-storage --timeout=900s || restore_status=$?
    else
      restore_status=1
      echo "ERROR: Could not restore the DaemonSet selector; keeping temporary node labels so selected owners remain schedulable." >&2
    fi
  fi
  if ((selector_restored || !selector_patched)); then
    while IFS= read -r node; do
      [[ -n "$node" ]] && kubectl label node "$node" bench.mooncake/owner- >/dev/null 2>&1
    done < <(kubectl get nodes -o name)
  fi
  rm -rf "$TMP_DIR"
  if ((selector_patched && !selector_restored)); then
    echo "ERROR: Mooncake DaemonSet nodeSelector was not restored." >&2
  else
    echo "Mooncake DaemonSet nodeSelector restored."
  fi
  if ((status == 0 && restore_status != 0)); then status=$restore_status; fi
  exit "$status"
}
trap restore EXIT INT TERM

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
for count in "${OWNER_COUNTS[@]}"; do
  echo "=== $count Mooncake owner(s), $CLIENTS_PER_OWNER clients per owner ==="
  for node in "${ELIGIBLE_NODES[@]}"; do
    kubectl label node "$node" bench.mooncake/owner=false --overwrite
  done
  for ((i=0; i<count; i++)); do
    kubectl label node "${READY_NODES[$i]}" bench.mooncake/owner=true --overwrite
  done

  python3 - "$ORIGINAL_SELECTOR" "$PATCH_FILE" <<'PY'
import json, sys
selector = json.load(open(sys.argv[1]))
selector["bench.mooncake/owner"] = "true"
patch = [{"op": "replace", "path": "/spec/template/spec/nodeSelector", "value": selector}]
with open(sys.argv[2], "w") as f:
    json.dump(patch, f)
PY
  kubectl -n "$NS" patch daemonset mooncake-storage --type=json \
    --patch-file="$PATCH_FILE" --dry-run=server >/dev/null
  selector_patched=1
  kubectl -n "$NS" patch daemonset mooncake-storage --type=json --patch-file="$PATCH_FILE"
  kubectl -n "$NS" rollout status daemonset/mooncake-storage --timeout=900s

  desired=$(kubectl -n "$NS" get daemonset mooncake-storage -o jsonpath='{.status.desiredNumberScheduled}')
  ready=$(kubectl -n "$NS" get daemonset mooncake-storage -o jsonpath='{.status.numberReady}')
  if [[ "$desired" != "$count" || "$ready" != "$count" ]]; then
    echo "Expected $count Ready Mooncake owners; found desired=$desired ready=$ready." >&2
    exit 1
  fi

  results="$ROOT/benchmarks/results-same-pool-${STAMP}-owners-${count}"
  OWNERS="$count" CLIENTS_PER_OWNER="$CLIENTS_PER_OWNER" \
    PROTOCOL="$PROTOCOL" DEVICE_NAME="$DEVICE_NAME" IMAGE="$IMAGE" \
    RESULTS="$results" bash "$ROOT/benchmarks/scale-store.sh"
  kubectl -n "$NS" delete pods -l app=mooncake-benchmark-client --wait=true
done
