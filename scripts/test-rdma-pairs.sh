#!/usr/bin/env bash
# Test every directed node pair over the DRANET-allocated RoCE v2 interface.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
IMAGE=${RDMA_TOOLS_IMAGE:?Set RDMA_TOOLS_IMAGE to the full pushed RDMA tools image reference}
NS=${NAMESPACE:-rdma-workloads}
DEVICE_CLASS=${DEVICE_CLASS:-dra.net}
RDMA_DEVICE=${RDMA_DEVICE:-mlx5_2}
RDMA_NETDEV=${RDMA_NETDEV:-ens800f0np0}
RUN_ID=$(date -u +%m%d%H%M%S)-$RANDOM
READY_TIMEOUT=${READY_TIMEOUT:-300s}
CONNECT_TIMEOUT=${CONNECT_TIMEOUT:-45s}
KEEP_PODS=${KEEP_PODS:-0}
RESULTS_DIR=${RESULTS_DIR:-"$ROOT/rdma-pair-results-$RUN_ID"}
mkdir -p "$RESULTS_DIR"
TMP_DIR=$(mktemp -d)
MANIFEST="$TMP_DIR/rdma-pods.json"
INVENTORY="$TMP_DIR/inventory.json"
NODES="$TMP_DIR/nodes.json"
SUMMARY="$RESULTS_DIR/results.tsv"
printf 'source_node\ttarget_node\tstatus\tbandwidth\n' > "$SUMMARY"

cleanup() {
  if [[ "$KEEP_PODS" != 1 && -s "$MANIFEST" ]]; then
    kubectl -n "$NS" delete -f "$MANIFEST" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

failures=0
kubectl -n "$NS" get namespace >/dev/null || exit 1
kubectl get deviceclass "$DEVICE_CLASS" >/dev/null || exit 1
kubectl get nodes -o json > "$NODES" || exit 1
python3 "$ROOT/scripts/render-rdma-pair-pods.py" \
  --nodes-json "$NODES" --image "$IMAGE" --run-id "$RUN_ID" \
  --namespace "$NS" --device-class "$DEVICE_CLASS" --interface "$RDMA_NETDEV" \
  > "$MANIFEST" 2> "$INVENTORY" || {
    cat "$INVENTORY" >&2
    exit 1
  }
cat "$INVENTORY"
not_ready_count=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["not_ready_nodes"]))' "$INVENTORY")
if (( not_ready_count > 0 )); then
  failures=$not_ready_count
  while IFS= read -r node; do
    printf '%s\t*\tSKIP_NODE_NOT_READY\t\n' "$node" >> "$SUMMARY"
  done < <(python3 -c 'import json,sys; print("\n".join(json.load(open(sys.argv[1]))["not_ready_nodes"]))' "$INVENTORY")
fi

kubectl apply --dry-run=server -f "$MANIFEST" || exit 1
kubectl apply -f "$MANIFEST" || exit 1
kubectl -n "$NS" wait --for=condition=Ready pod -l "rdma-pair-run=$RUN_ID" \
  --timeout="$READY_TIMEOUT" >/dev/null || echo "Some RDMA pods did not become Ready; testing available pairs." >&2

declare -a NODES_LIST PODS IPS GIDS AVAILABLE
count=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["ready_nodes"]))' "$INVENTORY")
for ((i=0; i<count; i++)); do
  entry=$(python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))["ready_nodes"][int(sys.argv[2])]))' "$INVENTORY" "$i")
  NODES_LIST[$i]=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["node"])' "$entry")
  PODS[$i]=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["pod"])' "$entry")
  pod=${PODS[$i]}
  IPS[$i]=''; GIDS[$i]=''; AVAILABLE[$i]=0
  if ! kubectl -n "$NS" get pod "$pod" -o jsonpath='{.status.phase}' 2>/dev/null | grep -qx Running; then
    echo "UNAVAILABLE ${NODES_LIST[$i]}: DRA pod $pod did not become Running" >&2
    failures=$((failures + 1))
    continue
  fi
  probe='set -eu
ip_addr=$(ip -o -4 addr show dev "$RDMA_NETDEV" | awk "{split(\$4,a,\"/\"); print a[1]; exit}")
test -n "$ip_addr"
gid_index=
for type_file in /sys/class/infiniband/"$RDMA_DEVICE"/ports/1/gid_attrs/types/*; do
  [ -f "$type_file" ] || continue
  idx=${type_file##*/}
  [ "$(cat "$type_file")" = "RoCE v2" ] || continue
  [ "$(cat "/sys/class/infiniband/$RDMA_DEVICE/ports/1/gid_attrs/ndevs/$idx")" = "$RDMA_NETDEV" ] || continue
  gid_index=$idx
  break
done
test -n "$gid_index"
printf "%s %s\n" "$ip_addr" "$gid_index"'
  if values=$(kubectl -n "$NS" exec "$pod" -- env RDMA_DEVICE="$RDMA_DEVICE" RDMA_NETDEV="$RDMA_NETDEV" sh -ec "$probe" 2>"$RESULTS_DIR/${pod}-preflight.log"); then
    read -r "IPS[$i]" "GIDS[$i]" <<< "$values"
    AVAILABLE[$i]=1
    echo "READY ${NODES_LIST[$i]} ip=${IPS[$i]} device=$RDMA_DEVICE gid=${GIDS[$i]}"
  else
    echo "UNAVAILABLE ${NODES_LIST[$i]}: interface/GID preflight failed (see $RESULTS_DIR/${pod}-preflight.log)" >&2
    failures=$((failures + 1))
  fi
done

for ((source=0; source<count; source++)); do
  for ((target=0; target<count; target++)); do
    (( source == target )) && continue
    source_node=${NODES_LIST[$source]}
    target_node=${NODES_LIST[$target]}
    source_pod=${PODS[$source]}
    target_pod=${PODS[$target]}
    client_log="$RESULTS_DIR/${source_node}-to-${target_node}.log"
    server_log="/tmp/rdma-pair-${RUN_ID}-${source}-${target}.log"
    saved_server_log="$RESULTS_DIR/${target_node}-server-for-${source_node}.log"
    if [[ ${AVAILABLE[$source]} != 1 || ${AVAILABLE[$target]} != 1 ]]; then
      printf '%s\t%s\tSKIP_PREFLIGHT\t\n' "$source_node" "$target_node" >> "$SUMMARY"
      continue
    fi
    server_cmd='nohup ib_write_bw -d "$RDMA_DEVICE" -x "$GID_INDEX" -s 65536 -n 1000 >"$SERVER_LOG" 2>&1 </dev/null & echo $!'
    server_pid=$(kubectl -n "$NS" exec "$target_pod" -- env RDMA_DEVICE="$RDMA_DEVICE" \
      GID_INDEX="${GIDS[$target]}" SERVER_LOG="$server_log" sh -ec "$server_cmd" \
      2>>"$RESULTS_DIR/server-start.log") || {
        printf '%s\t%s\tFAIL_SERVER_START\t\n' "$source_node" "$target_node" >> "$SUMMARY"
        failures=$((failures + 1)); continue
      }
    ready_cmd='i=0; while [ "$i" -lt 20 ]; do
  kill -0 "$SERVER_PID" 2>/dev/null || { cat "$SERVER_LOG"; exit 1; }
  grep -q "Waiting for client to connect" "$SERVER_LOG" && exit 0
  sleep 0.25; i=$((i+1))
done
cat "$SERVER_LOG"; exit 1'
    if ! kubectl -n "$NS" exec "$target_pod" -- env SERVER_PID="$server_pid" \
      SERVER_LOG="$server_log" sh -ec "$ready_cmd" >/dev/null 2>&1; then
      kubectl -n "$NS" exec "$target_pod" -- cat "$server_log" > "$saved_server_log" 2>/dev/null || true
      kubectl -n "$NS" exec "$target_pod" -- sh -c "kill '$server_pid' 2>/dev/null || true" >/dev/null 2>&1 || true
      printf '%s\t%s\tFAIL_SERVER_READY\t\n' "$source_node" "$target_node" >> "$SUMMARY"
      failures=$((failures + 1)); continue
    fi
    if kubectl -n "$NS" exec "$source_pod" -- timeout "${CONNECT_TIMEOUT}s" \
      ib_write_bw -d "$RDMA_DEVICE" -x "${GIDS[$source]}" -s 65536 -n 1000 \
      "${IPS[$target]}" > "$client_log" 2>&1; then
      rate=$(python3 - "$client_log" <<'PY'
import re,sys
text=open(sys.argv[1], encoding='utf-8', errors='replace').read()
rows=re.findall(r'^\s*65536\s+\d+\s+[\d.]+\s+([\d.]+)', text, re.M)
print(rows[-1] + ' MB/s' if rows else 'see log')
PY
)
      printf '%s\t%s\tPASS\t%s\n' "$source_node" "$target_node" "$rate" >> "$SUMMARY"
      echo "PASS $source_node -> $target_node: $rate"
    else
      printf '%s\t%s\tFAIL_RDMA\t\n' "$source_node" "$target_node" >> "$SUMMARY"
      echo "FAIL $source_node -> $target_node (see $client_log)" >&2
      failures=$((failures + 1))
    fi
    kubectl -n "$NS" exec "$target_pod" -- cat "$server_log" > "$saved_server_log" 2>/dev/null || true
    kubectl -n "$NS" exec "$target_pod" -- sh -c "kill '$server_pid' 2>/dev/null || true" >/dev/null 2>&1 || true
  done
done

echo "Results: $SUMMARY"
echo "Per-direction logs: $RESULTS_DIR"
if [[ "$KEEP_PODS" == 1 ]]; then
  echo "Diagnostic pods/claims kept; remove with: kubectl -n $NS delete pods,resourceclaims -l rdma-pair-run=$RUN_ID"
fi
if (( failures > 0 )); then
  echo "RDMA pair test completed with $failures failure(s)." >&2
  exit 1
fi
echo "RDMA pair test passed for every available directed node pair."
