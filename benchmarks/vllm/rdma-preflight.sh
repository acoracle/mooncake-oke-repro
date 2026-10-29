#!/usr/bin/env bash
# Read-only host checks, using the same debug/chroot/nsenter path previously used.
set -euo pipefail
if [[ -z ${NODES:-} ]]; then
  NODES=$(kubectl get nodes -l oci-rdma=true -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}')
fi
[[ -n "$NODES" ]] || { echo "No nodes labeled oci-rdma=true" >&2; exit 1; }
for node in $NODES; do
  output=$(kubectl debug "node/$node" -i \
    --image=docker.io/library/ubuntu:24.04 --profile=sysadmin -- \
    chroot /host /usr/bin/nsenter -t 1 -m -- /bin/bash -ec '
      hostname
      test -d /dev/infiniband
      test -d /sys/class/infiniband/mlx5_2/ports/1
      rdma link show mlx5_2/1 | tee /dev/stderr | grep -q "state ACTIVE"
      ip -4 addr show dev ens800f0np0 | tee /dev/stderr | grep -q "inet "
      echo "Host mlx5_2 GID mappings:"
      for path in /sys/class/infiniband/mlx5_2/ports/1/gid_attrs/ndevs/*; do
        printf "%s " "$path"; cat "$path" || true
      done
      echo MOONCAKE_RDMA_HOST_OK
    ' 2>&1)
  printf '%s\n' "$output"
  if ! printf '%s\n' "$output" | grep -q '^MOONCAKE_RDMA_HOST_OK$'; then
    echo "Host RDMA check failed for $node. Keep TCP; inspect the debug pod logs." >&2
    exit 1
  fi
done
echo 'Host RDMA interfaces are present. This check does not prove cross-node RDMA delivery.'
