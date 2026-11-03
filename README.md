# Mooncake Store on OKE BM.Optimized3.36

A reproducible lab kit for OKE workers with RoCE v2 RDMA, DRANET/DRA, node-local NVMe, Mooncake Store, its native store benchmark, and an optional CPU-only vLLM + Mooncake Store connector test.

This repo automates Kubernetes-side setup and image build/push. It does **not** create, resize, or reconfigure an OCI node pool. It is a lab reference, not a highly available or durable cache service: the master has one replica, cached data can disappear when nodes scale in, and applications must tolerate misses.

## What was exercised

The known-good environment was OKE 1.36 / CRI-O, Ubuntu 24.04, and BM.Optimized3.36 workers. Each worker exposed `ens800f0np0`, `mlx5_2`, 512 GiB RAM, and a 3.5 TiB `/dev/nvme0n1`. The cluster used DRANET chart v1.5.0 and `dra.net` DeviceClass. Mooncake source was pinned to `f7baeb138db8f14bb158e9fc6c84d1a1bd6178f6`; the vLLM image is pinned by digest and reports vLLM 0.32.0 / CPU PyTorch 2.13.0.

The assets here encode those versions and the node labels used in the lab. Image builds and deployment manifests must still be validated against your current OKE version and policies before use. This workspace cannot access your cluster or OCIR credentials, so it has not pushed images or applied manifests.

## Important networking distinction

DRANET allocates a RoCE interface to pods through Kubernetes Dynamic Resource Allocation. Install it and run the included DRA smoke test to verify the Kubernetes RDMA path.

The worker fabric is RoCE v2 over Ethernet (the verbs tooling may print link type Ethernet; it is not an InfiniBand fabric). The Mooncake owner DaemonSet in this kit uses the node's existing host RDMA device (`hostNetwork`, `/dev/infiniband`, `mlx5_2`) directly, as in the earlier lab. It does not request a DRANET `ResourceClaim`. Mooncake Store can also run over TCP. Start with TCP if uncertain, prove the deployment, then redeploy both owners and clients as RDMA together. Changing owner transport restarts the owners and clears their RAM cache.

## Prerequisites

On the build host: Podman or Docker, Git, Bash, and access to OCIR, GitHub, Ubuntu apt repositories, and PyPI. Prefer a Linux/amd64 build host; native C++ builds under Mac emulation can be slow and memory intensive.

On the operator/bastion: `kubectl` configured for the OKE cluster, Helm, Python 3, and permission to create namespaces, DeviceClasses, ResourceClaims, privileged host-network pods, DaemonSets, hostPath mounts, and node debugging pods. The cluster needs the OKE RDMA-enabled BM.Optimized3.36 node pool and the node labels `oci-rdma=true` and `oke-rdma-mode=dranet` for DRANET. The Mooncake DaemonSet selects `node.kubernetes.io/instance-type=BM.Optimized3.36` and `oci-rdma=true`.

Create `.env` locally from the example and fill in the tenancy namespace and OCIR username. Do not put an auth token in the file or commit it.

```bash
cp .env.example .env
# Edit .env, then load it in your shell when needed:
set -a; source .env; set +a
```

Example `.env` values:

```bash
REGISTRY=fra.ocir.io
OCIR_NAMESPACE=your-tenancy-namespace
OCIR_USERNAME=your-tenancy-namespace/OracleIdentityCloudService/your.user@example.com
TAG=lab-2026-10
```

OCIR repositories must exist or allow automatic creation. Configure the cluster image pull secret `mooncake/ocir-pull`. If a working secret already exists in `rdma-test`, deploy the Mooncake namespace first and copy it without exposing its data:

```bash
kubectl apply -f k8s/dranet/namespaces.yaml
bash scripts/copy-pull-secret.sh
```

If you do not already have the secret, create it with your OCIR auth token using your organization's standard secret-management method. Do not place the token in Git.

## 1. Build and push container images

The images are:

- `mooncake-store`: Mooncake master, owner client, Store Python binding, and benchmark sources, built CPU-only from the pinned Mooncake source.
- `rdma-tools`: `ib_write_bw`, `rdma`, `ibv_devinfo`, and networking diagnostics for the DRA smoke test.
- `vllm-mooncake`: optional CPU-only vLLM image plus Mooncake Store SDK/connector.

First build/push Mooncake and RDMA diagnostics. `podman login` (or Docker login) prompts for an OCI auth token; the password is never part of this script's arguments.

```bash
export ENGINE=podman
export OCIR_NAMESPACE=your-tenancy-namespace
export OCIR_USERNAME='your-tenancy-namespace/OracleIdentityCloudService/your.user@example.com'
export TAG=lab-2026-10
bash scripts/build-push.sh
```

To build and push the optional vLLM image too:

```bash
BUILD_VLLM=1 bash scripts/build-push.sh
```

If already logged in, use `SKIP_LOGIN=1`. If your Podman registry config is stored separately, set `PODMAN_CONFIG="$OCIR_AUTH_DIR"` (or export the existing `OCIR_AUTH_DIR`). For Docker use `ENGINE=docker`. The build script prints each pushed image reference. Use immutable digests in production or shared clusters; tags are convenient for this lab. Build logs are useful if the pinned upstream dependencies change.

Set the image references in your shell:

```bash
export STORE_IMAGE="$REGISTRY/$OCIR_NAMESPACE/mooncake-store:$TAG"
export RDMA_TOOLS_IMAGE="$REGISTRY/$OCIR_NAMESPACE/rdma-tools:$TAG"
export VLLM_IMAGE="$REGISTRY/$OCIR_NAMESPACE/vllm-mooncake:$TAG"
```

Use the **full OCIR image reference**, including the registry hostname, whenever setting an image for Kubernetes: `fra.ocir.io/<tenancy-namespace>/<repository>:<tag>` (for example, `fra.ocir.io/fr9qm01oq44x/mooncake-store:5ac6dec`). Do not use a short name such as `<tenancy-namespace>/mooncake-store:5ac6dec`; CRI-O may reject it as ambiguous. Set `STORE_IMAGE` separately before expanding it as `IMAGE`, for example:

```bash
export STORE_IMAGE=fra.ocir.io/fr9qm01oq44x/mooncake-store:5ac6dec
IMAGE="$STORE_IMAGE" PROTOCOL=tcp bash scripts/deploy-mooncake.sh
```

Avoid writing `STORE_IMAGE=... IMAGE="$STORE_IMAGE"` on the same command line: the shell expands `$STORE_IMAGE` before applying that command's temporary assignment.

## 2. Install DRANET and verify RDMA allocation

Confirm your node pool carries the labels that select the driver, then install the pinned Helm chart, namespaces, and DeviceClass:

```bash
kubectl get nodes -L node.kubernetes.io/instance-type,oci-rdma,oke-rdma-mode
bash scripts/install-dranet.sh
kubectl -n kube-system get daemonset dranet
kubectl get deviceclasses
kubectl get resourceslices -o wide
```

Run a two-pod RDMA smoke test; the pods request `ens800f0np0` from DRANET and anti-affinity places them on different workers:

```bash
RDMA_TOOLS_IMAGE="$RDMA_TOOLS_IMAGE" bash scripts/apply-rdma-smoke.sh
```

The script reports the two DRA interface addresses. In one terminal, start the server using RoCE v2 GID index 5. On the tested BM.Optimized3.36 setup, index 3 was an all-zero GID; index 5 maps to `ens800f0np0` and is RoCE v2:

```bash
kubectl -n rdma-workloads exec -it rdma-smoke-a -- ib_write_bw -d mlx5_2 -x 5
```

In another terminal, connect the other pod to the server address printed by the script:

```bash
kubectl -n rdma-workloads exec -it rdma-smoke-b -- ib_write_bw -d mlx5_2 -x 5 <RDMA_SMOKE_A_IP>
```

If using a different NIC or node shape, inspect `/sys/class/infiniband/mlx5_2/ports/1/gid_attrs/` in both pods and select the GID index whose type is `RoCE v2` and whose netdev is `ens800f0np0`. Use that index on both server and client (`-x`); `-F` only changes CPU-frequency warning behavior.

A successful bandwidth summary proves the DRA-allocated pod path between those two nodes. `rdma link show` reporting ACTIVE by itself only proves local link state. Clean up the smoke claims/pods when done:

```bash
kubectl -n rdma-workloads delete -f k8s/dranet/rdma-smoke.yaml
```

## 3. Prepare node-local NVMe

Inspect every worker before formatting anything. The script targets `/dev/nvme0n1`; change it if your shape exposes a different device. Verify that the disk is the intended local NVMe and contains no data you need:

```bash
for NODE in $(kubectl get nodes -l oci-rdma=true -o name); do
  kubectl debug "$NODE" -i --image=docker.io/library/ubuntu:24.04 --profile=sysadmin -- \
    chroot /host /usr/bin/nsenter -t 1 -m -- /bin/bash -ec \
    'hostname; lsblk -o NAME,TYPE,SIZE,FSTYPE,LABEL,MOUNTPOINTS /dev/nvme0n1; wipefs --no-act /dev/nvme0n1; free -h'
done
```

`prepare-nvme.sh` refuses disks with partitions, signatures, holders, unexpected mounts, or an existing filesystem other than the labeled Mooncake ext4 filesystem. When explicitly enabled, it formats **only a blank disk** as ext4 with label `mooncake-nvme`, mounts it at `/mnt/mooncake-nvme`, and creates `/mnt/mooncake-nvme/store`. The DaemonSet init container can repeat this guarded setup as new labeled workers join.

To enable automatic preparation, use both explicit settings below. Do this only after confirming that `/dev/nvme0n1` is disposable on every eligible and future node:

```bash
AUTO_PREPARE_NVME=1 \
CONFIRM_BLANK_NVME_FORMAT=I_UNDERSTAND_EMPTY_DISKS_ONLY \
IMAGE="$STORE_IMAGE" PROTOCOL=tcp \
bash scripts/deploy-mooncake.sh
```

Without the two confirmation settings, the renderer does not add the privileged NVMe preparation init container. In that mode, run `scripts/prepare-nvme.sh` as root on every worker yourself, then deploy Mooncake. A stopped/absent mount will make the owner fail its startup check rather than silently putting cache data on the boot volume.

Verify mounts on each node and in the owner pods:

```bash
kubectl -n mooncake get pods -o wide
kubectl -n mooncake logs -l app=mooncake-storage -c prepare-local-nvme --prefix --tail=50
kubectl -n mooncake exec -it <mooncake-storage-pod> -c store -- findmnt /host-mnt/mooncake-nvme
```

The included reference settings reserve 128 GiB of RAM per owner and configure a 3,000,000,000,000-byte logical SSD quota. Review RAM, quota, memory limits, available node memory, and the disk size before changing them.

## 4. Deploy Mooncake Store

The deployment is one master Deployment plus one owner per eligible node. The master uses a ClusterIP service. Owners advertise the node private IP and expose their service/data ports over the private worker network. Keep this path private; this kit does not create NSGs, public endpoints, or firewall rules.

If you enabled automatic NVMe preparation in Section 3, that command already deployed Mooncake over TCP and waited for the master and storage DaemonSet rollouts. Do not run the deploy command again; continue with the checks below. If you prepared NVMe manually, deploy Mooncake over TCP once now:

```bash
IMAGE="$STORE_IMAGE" PROTOCOL=tcp bash scripts/deploy-mooncake.sh
```

Check the deployment:

```bash
kubectl -n mooncake get pods -o wide
kubectl -n mooncake logs deployment/mooncake-master --tail=80
kubectl -n mooncake logs -l app=mooncake-storage -c store --prefix --tail=80
```

After TCP is healthy and you have confirmed the host RDMA preconditions, switch the owner deployment to RoCE/RDMA:

```bash
PROTOCOL=rdma IMAGE="$STORE_IMAGE" bash scripts/deploy-mooncake.sh
kubectl -n mooncake rollout status daemonset/mooncake-storage --timeout=900s
kubectl -n mooncake logs -l app=mooncake-storage -c store --prefix --tail=120 | grep -E 'RDMA device|mlx5_2|error|ERROR'
```

This setting uses `mlx5_2` and `MC_IB_TC=41`, matching the tested BM.Optimized3.36 setup. It grants owner pods privileged access to `/dev/infiniband` for the host-network RDMA path. To use another NIC, pass `--device-names` to `render.py` through a local edit or adapt the script and verify the selected RoCE port/GID first. Return to TCP with `PROTOCOL=tcp` and rerun deployment; this restarts owners and loses their RAM cache.

Master/metadata/metrics checks:

```bash
kubectl -n mooncake port-forward service/mooncake-master 19003:9003
# In another shell:
curl -fsS http://127.0.0.1:19003/health
curl -fsS http://127.0.0.1:19003/get_segments_detail
curl -fsS http://127.0.0.1:19003/metrics/summary
```

The NVMe filesystem being mounted and the SSD offload backend being configured do not prove that a benchmark wrote data to NVMe. The scale benchmark below intentionally uses RAM replicas only, since the lab objective is worker/client scaling rather than NVMe performance.

## 5. Optional Mooncake Store benchmark

### Single benchmark client

Run the included correctness + throughput sequence against the deployed owners. It verifies payloads, does a fixed-size write, then timed reads. It saves each log and JSON summary in a unique `benchmarks/mooncake-results-*` folder.

```bash
IMAGE="$STORE_IMAGE" PROTOCOL=rdma DEVICE_NAME=mlx5_2 \
  bash benchmarks/benchmark-store.sh
```

Start with `PROTOCOL=tcp` if the owners are using TCP. This client needs the matching protocol and, for RDMA, host networking plus device access. This is a useful functional/latency smoke test; it does not measure a distributed scale-out curve.

### Multi-client / owner-scale sweep

Scale the OKE node pool to the desired number of workers through your normal OCI/Resource Manager process. The DaemonSet follows workers with the matching labels. Wait for exactly one Ready owner per worker, and check Dranet/RDMA and NVMe state after every scale event:

```bash
kubectl get nodes -L node.kubernetes.io/instance-type,oci-rdma,oke-rdma-mode
kubectl -n mooncake get pods -l app=mooncake-storage -o wide
```

`scale-store.sh` refuses a requested owner count that does not match the running owner DaemonSet. It launches one independent native Store benchmark client per requested client, pins clients across the worker nodes, and adds each client's read throughput to report aggregate MiB/s. Every client prepares 4 GiB (4,096 × 1 MiB) with a unique key prefix, then runs a 30-second sequential read workload. With eight clients per worker, the total dataset is 32 GiB per worker if placement is balanced. It uses memory replicas only (`dfs-replica-num=0`); this is not an NVMe test.

Example, with a four-worker node pool and four Ready owners:

```bash
OWNERS=4 CLIENTS_PER_OWNER=8 PROTOCOL=rdma DEVICE_NAME=mlx5_2 \
IMAGE="$STORE_IMAGE" bash benchmarks/scale-store.sh
```

For comparisons, rerun at `OWNERS=1`, `2`, and `4` only after resizing the worker pool to exactly that count, using the same client-per-owner ratio, object size/count, duration, transport, and fresh run. Repeat each point at least three times and report median plus range. To isolate client concurrency, keep the node pool and owner count fixed (for example four owners) while sweeping `CLIENTS_PER_OWNER=2,4,8`. Don’t change owner count and client concurrency together if the aim is to identify the bottleneck.

Every run leaves its benchmark pods and cache keys for inspection. Remove only the benchmark clients after copying results:

```bash
kubectl -n mooncake delete pods -l app=mooncake-benchmark-client
```

Do not delete the owner DaemonSet or cache directory as benchmark cleanup. Capture worker CPU, memory, and NIC counters alongside throughput; zero misses, failed requests, and verify failures are required before interpreting a throughput number.

## 6. Optional vLLM CPU benchmark using the native Mooncake Store connector

This package uses vLLM's native `MooncakeStoreConnector`, not LMCache. It is a CPU-only functionality/performance experiment on the BM workers, using Qwen2.5-0.5B-Instruct in float32. It is not a GPU inference result and not a production serving configuration. The earlier LMCache + Mooncake build required matching Mooncake C++ dependency headers and was not validated, so no LMCache image or manifest is represented as working here.

Build/push the optional vLLM image with `BUILD_VLLM=1`. Deploy it on a worker with a free host port 8000. Set `NODE` to the Kubernetes node name and `OWNER` to a different Mooncake owner's private IP plus port 50053. The transport must match the owners:

```bash
NODE=<vllm-worker-node-name> \
OWNER=<mooncake-owner-private-ip>:50053 \
PROTOCOL=rdma \
IMAGE="$VLLM_IMAGE" \
bash benchmarks/vllm/deploy-vllm.sh
```

For TCP, set `PROTOCOL=tcp`. RDMA mode runs a read-only check against worker interfaces before deploying, but still needs successful external KV evidence. Open a local tunnel and send a simple OpenAI API request:

```bash
kubectl -n mooncake port-forward deployment/vllm-mooncake 8000:8000
curl -fsS http://127.0.0.1:8000/v1/models
```

Before measuring performance, prove external KV is used: the script sends the same deterministic prompt, restarts only vLLM, repeats it, checks output equality, and requires Mooncake load-tier log evidence.

```bash
bash benchmarks/vllm/check-cache.sh
```

Then collect cold/warm request throughput, TTFT, TPOT, and end-to-end latency:

```bash
bash benchmarks/vllm/benchmark-cache.sh
OUTPUT_TOKENS=512 CONCURRENCY=4 bash benchmarks/vllm/benchmark-cache.sh
```

The benchmark script uses 32 deterministic 4,096-token inputs, an explicit model revision, and compares Store-cold to Store-warm runs separated by a vLLM process restart. Repeat it with the same settings for stable comparisons. This measures KV reuse from Mooncake after restart; it is not remote attention/KV fetching on every generated decode token, nor a connector-free A/B comparison. Inspect the saved warm vLLM logs for positive successful Mooncake loads and zero failed loads before claiming a cache hit.

For RDMA, both owners and requester must use `PROTOCOL=rdma`; RDMA link initialization alone does not prove KV payload traffic. Compare `mlx5_2` port counters before/after a warm run and correlate the increase with successful external loads. Owner transport changes restart the owners and clear their RAM cache.

## 7. Recorded scale results from the earlier lab

These summary figures were recorded in the task conversation; raw logs are not bundled. They are a reference for reruns, not a promise that a new cluster will match them.

| Ready owners | Independent clients | Mean aggregate read throughput | Quality notes |
|---:|---:|---:|---|
| 1 | 8 | 8,993.5 MiB/s | 3/3 runs clean |
| 2 | 16 | 14,398.6 MiB/s | 49 misses / 16 failed requests total; 2/3 runs clean |
| 4 | 32 | 15,871.2 MiB/s | 154 misses / 26 failed requests total; no verification failures |

The 2→4 owner step added about 10% aggregate throughput while errors increased. These results do not establish a Mooncake hard limit because owner count and client count changed together. Rerun clean controlled sweeps before scaling beyond four workers.

## Troubleshooting and cleanup

```bash
kubectl -n mooncake get pods -o wide
kubectl -n mooncake describe pod <pod-name>
kubectl -n mooncake logs <pod-name> --all-containers --tail=200
kubectl -n kube-system get pods -l app.kubernetes.io/name=dranet -o wide
kubectl get resourceclaims -A
kubectl get resourceslices -o wide
```

The hostNetwork owner and vLLM paths use private node IPs and dynamically allocated transfer ports. Check private VCN routing/security lists/NSGs for worker-to-worker reachability if metadata works but data transfers fail. Keep the service private and restrict ingress to trusted subnets.

To remove only the optional inference deployment and test clients:

```bash
kubectl -n mooncake delete deployment vllm-mooncake --ignore-not-found
kubectl -n mooncake delete service vllm-mooncake --ignore-not-found
kubectl -n mooncake delete pods -l app=mooncake-benchmark-client --ignore-not-found
```

To remove Mooncake Store, first confirm nothing is using it; then delete `mooncake-master` and `mooncake-storage` resources in the generated manifest. Do not remove local NVMe filesystems unless you explicitly intend to erase the cache. To uninstall DRANET, use Helm and delete its DeviceClass only after no ResourceClaims depend on it.

## Validation commands

```bash
bash scripts/validate.sh
```

For a live cluster, use server-side validation before applying a rendered deployment:

```bash
python3 k8s/mooncake/render.py --image "$STORE_IMAGE" --protocol tcp > /tmp/mooncake.yaml
kubectl apply --dry-run=server -f /tmp/mooncake.yaml
```

## Upstream references

- [DRANET install and DRA quick start](https://github.com/kubernetes-sigs/dranet)
- [Mooncake Store deployment and tuning](https://github.com/kvcache-ai/Mooncake/blob/f7baeb138db8f14bb158e9fc6c84d1a1bd6178f6/docs/source/deployment/mooncake-store-deployment-guide.md)
- [Mooncake SSD offload configuration](https://github.com/kvcache-ai/Mooncake/blob/f7baeb138db8f14bb158e9fc6c84d1a1bd6178f6/docs/source/deployment/ssd/ssd-offload.md)
- [vLLM v0.32 Mooncake Store connector guide](https://docs.vllm.ai/en/v0.32.0/features/mooncake_store_connector_usage/)
- [Oracle Compute shapes](https://docs.oracle.com/en-us/iaas/Content/Compute/References/computeshapes.htm)
