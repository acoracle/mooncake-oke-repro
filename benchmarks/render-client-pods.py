#!/usr/bin/env python3
"""Render host-networked Mooncake benchmark clients pinned to selected workers."""
import argparse
import json

p = argparse.ArgumentParser()
p.add_argument('--nodes-json', required=True)
p.add_argument('--owners', type=int, required=True)
p.add_argument('--clients-per-owner', type=int, default=8)
p.add_argument('--image', required=True)
p.add_argument('--namespace', default='mooncake')
p.add_argument('--protocol', choices=('tcp', 'rdma'), default='tcp')
a = p.parse_args()
nodes = json.loads(a.nodes_json)
if len(nodes) < a.owners:
    p.error(f'Only {len(nodes)} ready owners found; requested {a.owners}')
items = []
for owner_index, node in enumerate(nodes[:a.owners]):
    for local_index in range(a.clients_per_owner):
        index = owner_index * a.clients_per_owner + local_index
        name = f'mcbench-{index:03d}'
        container = {
            'name': 'bench', 'image': a.image, 'imagePullPolicy': 'IfNotPresent',
            'command': ['/bin/bash', '-ec'], 'args': ['sleep infinity'],
            'env': [
                {'name': 'POD_IP', 'valueFrom': {'fieldRef': {'fieldPath': 'status.podIP'}}},
                {'name': 'MC_TCP_BIND_ADDRESS', 'valueFrom': {'fieldRef': {'fieldPath': 'status.podIP'}}},
                {'name': 'MC_IB_TC', 'value': '41'},
                {'name': 'PROTOCOL', 'value': a.protocol},
            ],
            'resources': {'requests': {'cpu': '1', 'memory': '1Gi'}, 'limits': {'memory': '6Gi'}},
        }
        spec = {
            'restartPolicy': 'Never', 'hostNetwork': True, 'dnsPolicy': 'ClusterFirstWithHostNet',
            'nodeName': node, 'automountServiceAccountToken': False,
            'imagePullSecrets': [{'name': 'ocir-pull'}], 'containers': [container],
        }
        if a.protocol == 'rdma':
            container['securityContext'] = {'privileged': True, 'runAsUser': 0}
            container['volumeMounts'] = [{'name': 'infiniband', 'mountPath': '/dev/infiniband'}]
            spec['volumes'] = [{'name': 'infiniband', 'hostPath': {'path': '/dev/infiniband', 'type': 'Directory'}}]
        items.append({'apiVersion': 'v1', 'kind': 'Pod',
                      'metadata': {'name': name, 'namespace': a.namespace,
                                   'labels': {'app': 'mooncake-benchmark-client', 'client-index': str(index)}},
                      'spec': spec})
print(json.dumps({'apiVersion': 'v1', 'kind': 'List', 'items': items}, indent=2))
