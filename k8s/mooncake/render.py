#!/usr/bin/env python3
"""Render a private, single-master Mooncake cache deployment (standard library only)."""
import argparse
import hashlib
import json
from pathlib import Path

p = argparse.ArgumentParser()
p.add_argument('--image', required=True)
p.add_argument('--ram-gib', type=int, default=128)
p.add_argument('--disk-bytes', type=int, default=3_000_000_000_000)
p.add_argument('--protocol', choices=('tcp', 'rdma'), default='tcp')
p.add_argument('--device-names', default='mlx5_2')
p.add_argument('--auto-prepare-nvme', action='store_true',
               help='Initialize unused NVMe disks on joining BM workers using the guarded script.')
a = p.parse_args()
if not 1 <= a.ram_gib <= 400 or not 1_000_000_000 <= a.disk_bytes <= 3_100_000_000_000:
    p.error('RAM must be 1–400 GiB; disk quota 1 GB–3.1 TB for this reference shape.')

ns = 'mooncake'
selector = {'node.kubernetes.io/instance-type': 'BM.Optimized3.36', 'oci-rdma': 'true'}
master_address = 'mooncake-master.mooncake.svc.cluster.local:50051'
metadata_address = 'http://mooncake-master.mooncake.svc.cluster.local:8080/metadata'
script = Path(__file__).with_name('prepare-nvme.sh').read_text()

def obj(kind, name, spec=None, **extra):
    value = {'apiVersion': 'apps/v1' if kind in ('Deployment', 'DaemonSet') else 'v1',
             'kind': kind, 'metadata': {'name': name, 'namespace': ns}, **extra}
    if spec is not None:
        value['spec'] = spec
    return value

def probe(port, path='/health'):
    return {'httpGet': {'path': path, 'port': port}, 'periodSeconds': 10, 'timeoutSeconds': 5}

items = [obj('Namespace', ns)]
items[0]['metadata'].pop('namespace')
items.append(obj('Service', 'mooncake-master', {
    'type': 'ClusterIP', 'selector': {'app': 'mooncake-master'},
    'ports': [{'name': name, 'port': port, 'targetPort': port}
              for name, port in [('rpc', 50051), ('metadata', 8080), ('admin', 9003)]]}))

master = {
    'name': 'master', 'image': a.image, 'imagePullPolicy': 'IfNotPresent',
    'command': ['mooncake_master'],
    'args': ['--rpc_port=50051', '--rpc_thread_num=4', '--enable_offload=true',
             '--offload_on_evict=true', '--promotion_on_hit=true',
             '--enable_http_metadata_server=true', '--http_metadata_server_port=8080',
             '--enable_metadata_cleanup_on_timeout=true', '--metrics_port=9003',
             '--metrics_host=0.0.0.0', '--enable_metric_reporting=true', '--logtostderr'],
    'ports': [{'containerPort': port} for port in (50051, 8080, 9003)],
    'resources': {'requests': {'cpu': '1', 'memory': '2Gi'}, 'limits': {'memory': '8Gi'}},
    'securityContext': {'allowPrivilegeEscalation': False, 'capabilities': {'drop': ['ALL']}},
    'startupProbe': {**probe(9003), 'failureThreshold': 60},
    'readinessProbe': probe(9003),
}
items.append(obj('Deployment', 'mooncake-master', {
    'replicas': 1, 'strategy': {'type': 'Recreate'},
    'selector': {'matchLabels': {'app': 'mooncake-master'}},
    'template': {'metadata': {'labels': {'app': 'mooncake-master'}}, 'spec': {
        'automountServiceAccountToken': False,
        'terminationGracePeriodSeconds': 60,
        'imagePullSecrets': [{'name': 'ocir-pull'}], 'containers': [master]}}}))

config = {
    'MOONCAKE_MASTER': master_address,
    'MOONCAKE_METADATA': metadata_address,
    'MOONCAKE_RAM_BYTES': str(a.ram_gib * 1024**3),
    'MOONCAKE_OFFLOAD_FILE_STORAGE_PATH': '/host-mnt/mooncake-nvme/store',
    'MOONCAKE_OFFLOAD_STORAGE_BACKEND_DESCRIPTOR': 'bucket_storage_backend',
    'MOONCAKE_OFFLOAD_LOCAL_BUFFER_SIZE_BYTES': '1073741824',
    'MOONCAKE_OFFLOAD_TOTAL_SIZE_LIMIT_BYTES': str(a.disk_bytes),
    'MOONCAKE_OFFLOAD_BUCKET_MAX_TOTAL_SIZE': str(a.disk_bytes),
    'MOONCAKE_OFFLOAD_BUCKET_MAX_PHYSICAL_BYTES': str(a.disk_bytes + 100_000_000_000),
    'MOONCAKE_OFFLOAD_BUCKET_EVICTION_POLICY': 'lru',
    'MC_STORE_CLIENT_METRIC': '1',
    'MC_RPC_CONNECT_TIMEOUT_MS': '3000',
}
items.append(obj('ConfigMap', 'mooncake-storage-config', data=config))
if a.auto_prepare_nvme:
    items.append(obj('ConfigMap', 'mooncake-nvme-bootstrap', data={'prepare-nvme.sh': script}))

mount = {'name': 'host-mnt', 'mountPath': '/host-mnt', 'mountPropagation': 'HostToContainer'}
mount_check = '''
test "$(findmnt -nro FSTYPE --mountpoint /host-mnt/mooncake-nvme)" = ext4
test -d /host-mnt/mooncake-nvme/store
test -w /host-mnt/mooncake-nvme/store
'''
entry = mount_check + '''
if [ "$MOONCAKE_PROTOCOL" = rdma ]; then ulimit -l unlimited; fi
if [ "$MOONCAKE_PROTOCOL" = rdma ]; then
  MOONCAKE_DEVICE_ARGS="--device_names=${MOONCAKE_DEVICE_NAMES}"
else
  MOONCAKE_DEVICE_ARGS=""
fi
exec mooncake_client \
  --host="${NODE_IP}:50053" --port=50052 --protocol="$MOONCAKE_PROTOCOL" \
  ${MOONCAKE_DEVICE_ARGS} \
  --master_server_address="$MOONCAKE_MASTER" \
  --metadata_server="$MOONCAKE_METADATA" \
  --global_segment_size="$MOONCAKE_RAM_BYTES" \
  --local_buffer_size=1073741824 --threads=4 \
  --enable_offload=true --start_offload_rpc_server=true \
  --enable_http_server=true --http_port=9300 --logtostderr
'''
store = {
    'name': 'store', 'image': a.image, 'imagePullPolicy': 'IfNotPresent',
    'command': ['/bin/bash', '-ec'], 'args': [entry],
    'envFrom': [{'configMapRef': {'name': 'mooncake-storage-config'}}],
    'env': [{'name': 'NODE_IP', 'valueFrom': {'fieldRef': {'fieldPath': 'status.hostIP'}}},
            {'name': 'MC_TCP_BIND_ADDRESS', 'valueFrom': {'fieldRef': {'fieldPath': 'status.hostIP'}}},
            {'name': 'MOONCAKE_PROTOCOL', 'value': a.protocol},
            {'name': 'MOONCAKE_DEVICE_NAMES', 'value': a.device_names},
            {'name': 'MC_IB_TC', 'value': '41'}],
    'volumeMounts': [mount],
    'resources': {'requests': {'cpu': '2', 'memory': f'{a.ram_gib + 8}Gi'},
                  'limits': {'memory': f'{a.ram_gib + 32}Gi'}},
    'securityContext': {'privileged': False, 'allowPrivilegeEscalation': False,
                        'capabilities': {'drop': ['ALL'], 'add': ['IPC_LOCK']}},
    'startupProbe': {**probe(9300), 'failureThreshold': 180},
    'readinessProbe': probe(9300),
}
spec = {
    'hostNetwork': True, 'dnsPolicy': 'ClusterFirstWithHostNet',
    'nodeSelector': selector, 'automountServiceAccountToken': False,
    'imagePullSecrets': [{'name': 'ocir-pull'}],
    'terminationGracePeriodSeconds': 120,
    'containers': [store],
    'volumes': [{'name': 'host-mnt', 'hostPath': {'path': '/mnt', 'type': 'Directory'}}],
}
if a.auto_prepare_nvme:
    spec['hostPID'] = True
    spec['volumes'] += [
        {'name': 'host-root', 'hostPath': {'path': '/', 'type': 'Directory'}},
        {'name': 'bootstrap', 'configMap': {'name': 'mooncake-nvme-bootstrap'}}]
    spec['initContainers'] = [{
        'name': 'prepare-local-nvme', 'image': a.image,
        'securityContext': {'privileged': True},
        'command': ['/bin/bash', '-ec'],
        'args': ['SCRIPT="$(cat /bootstrap/prepare-nvme.sh)"; exec chroot /host /usr/bin/nsenter -t 1 -m -- /bin/bash -c "$SCRIPT"'],
        'volumeMounts': [{'name': 'host-root', 'mountPath': '/host'},
                         {'name': 'bootstrap', 'mountPath': '/bootstrap', 'readOnly': True}]
    }]
if a.protocol == 'rdma':
    store['securityContext'] = {'privileged': True, 'runAsUser': 0}
    store['volumeMounts'].append({'name': 'infiniband', 'mountPath': '/dev/infiniband'})
    spec['volumes'].append({'name': 'infiniband', 'hostPath': {
        'path': '/dev/infiniband', 'type': 'Directory'}})

digest = hashlib.sha256((json.dumps(config, sort_keys=True) + script).encode()).hexdigest()
items.append(obj('DaemonSet', 'mooncake-storage', {
    'selector': {'matchLabels': {'app': 'mooncake-storage'}},
    'updateStrategy': {'type': 'RollingUpdate', 'rollingUpdate': {'maxUnavailable': 1}},
    'template': {'metadata': {'labels': {'app': 'mooncake-storage'},
                              'annotations': {'mooncake/config-sha256': digest}}, 'spec': spec}}))
print(json.dumps({'apiVersion': 'v1', 'kind': 'List', 'items': items}, indent=2))
