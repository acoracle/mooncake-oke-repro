#!/usr/bin/env python3
"""Render a standalone requester against the existing mooncake namespace."""
import argparse
import json
import re

p = argparse.ArgumentParser()
p.add_argument("--image", required=True)
p.add_argument("--protocol", choices=("tcp", "rdma"), default="tcp")
p.add_argument("--node", required=True)
p.add_argument("--owner", required=True)
p.add_argument("--device-name", default="mlx5_2")
p.add_argument("--model-revision", required=True)
a = p.parse_args()
if not re.fullmatch(r"[0-9a-f]{40}", a.model_revision):
    p.error("--model-revision must be a full Hugging Face commit SHA")
ns = "mooncake"
name = "vllm-mooncake"
conf = {
    "mode": "standalone-store",
    "metadata_server": "http://mooncake-master.mooncake.svc.cluster.local:8080/metadata",
    "master_server_address": "mooncake-master.mooncake.svc.cluster.local:50051",
    "global_segment_size": 0, "local_buffer_size": 268435456,
    "protocol": a.protocol, "device_name": a.device_name if a.protocol == "rdma" else "",
    "enable_offload": True,
}
transfer = {
    "kv_connector": "MooncakeStoreConnector", "kv_role": "kv_both",
    "kv_connector_extra_config": {
        "load_async": True, "cache_prefix": f"cpu-mooncake-{a.protocol}-{a.model_revision}-v1",
    },
}
env = {
    "MOONCAKE_CONFIG_PATH": "/etc/mooncake/config.json",
    "MOONCAKE_PREFERRED_SEGMENT": a.owner,
    "VLLM_MOONCAKE_STORE_TIER_LOG": "1",
    # Owner in the deployed package has a 1 GiB SSD staging buffer. The
    # connector's 1280 MiB estimate * 0.5 keeps sub-batches safely below it.
    "VLLM_MOONCAKE_DISK_STAGING_USABLE_RATIO": "0.5",
    "MC_STORE_CLIENT_METRIC": "1", "MC_IB_TC": "41",
    "VLLM_CPU_KVCACHE_SPACE": "8", "OMP_NUM_THREADS": "16",
    "VLLM_CPU_OMP_THREADS_BIND": "nobind", "PYTHONHASHSEED": "0",
    "HF_HOME": "/model-cache",
}
start = "python3 /opt/integration/preflight.py\n"
if a.protocol == "rdma":
    start += f"ulimit -l unlimited\nibv_devinfo -d {a.device_name}\n"
start += "exec vllm serve Qwen/Qwen2.5-0.5B-Instruct " + " ".join([
    "--served-model-name=cpu-test", "--host=0.0.0.0", "--port=8000",
    "--dtype=float32", "--tensor-parallel-size=1", "--max-model-len=8192",
    "--max-num-seqs=4", "--max-num-batched-tokens=4096",
    "--enable-prefix-caching", "--generation-config=vllm",
    f"--revision={a.model_revision}", f"--tokenizer-revision={a.model_revision}",
    "--kv-transfer-config='" + json.dumps(transfer, separators=(",", ":")) + "'",
])
container = {
    "name": "vllm", "image": a.image,
    "command": ["/bin/bash", "-ec"], "args": [start],
    "env": [{"name": k, "value": v} for k, v in env.items()] + [
        {"name": k, "valueFrom": {"fieldRef": {"fieldPath": "status.hostIP"}}}
        for k in ("VLLM_HOST_IP", "MC_TCP_BIND_ADDRESS", "MOONCAKE_REQUESTER_LOCAL_HOSTNAME")
    ],
    "resources": {"requests": {"cpu": "16", "memory": "24Gi"},
                  "limits": {"cpu": "16", "memory": "48Gi"}},
    "volumeMounts": [{"name": "config", "mountPath": "/etc/mooncake", "readOnly": True},
                     {"name": "scripts", "mountPath": "/scripts", "readOnly": True},
                     {"name": "shm", "mountPath": "/dev/shm"},
                     {"name": "models", "mountPath": "/model-cache"}],
    "startupProbe": {"httpGet": {"path": "/health", "port": 8000},
                     "timeoutSeconds": 5, "periodSeconds": 10, "failureThreshold": 180},
    "readinessProbe": {"httpGet": {"path": "/health", "port": 8000},
                       "timeoutSeconds": 5, "periodSeconds": 10},
}
spec = {
    "nodeSelector": {"kubernetes.io/hostname": a.node},
    "hostNetwork": True, "dnsPolicy": "ClusterFirstWithHostNet",
    "automountServiceAccountToken": False, "imagePullSecrets": [{"name": "ocir-pull"}],
    "containers": [container],
    "volumes": [{"name": "config", "configMap": {"name": name}},
                {"name": "scripts", "configMap": {"name": name + "-scripts"}},
                {"name": "shm", "emptyDir": {"medium": "Memory", "sizeLimit": "4Gi"}},
                {"name": "models", "emptyDir": {"sizeLimit": "6Gi"}}],
}
if a.protocol == "rdma":
    # This lab path uses the existing host RDMA interface; it does not move or
    # claim the NIC via Dranet. Privilege permits host uverbs access and memlock.
    container["securityContext"] = {"privileged": True, "runAsUser": 0}
    container["volumeMounts"].append({"name": "verbs", "mountPath": "/dev/infiniband"})
    spec["volumes"].append({"name": "verbs", "hostPath": {
        "path": "/dev/infiniband", "type": "Directory"}})
items = [
    {"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"name": name, "namespace": ns},
     "data": {"config.json": json.dumps(conf, indent=2), "model-revision": a.model_revision}},
    {"apiVersion": "apps/v1", "kind": "Deployment",
     "metadata": {"name": name, "namespace": ns},
     "spec": {"replicas": 1, "strategy": {"type": "Recreate"},
              "selector": {"matchLabels": {"app": name}},
              "template": {"metadata": {"labels": {"app": name},
                                        "annotations": {"mooncake-protocol": a.protocol}},
                           "spec": spec}}},
]
print(json.dumps({"apiVersion": "v1", "kind": "List", "items": items}, indent=2))
