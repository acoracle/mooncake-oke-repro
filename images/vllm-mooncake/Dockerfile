# vLLM CPU + Mooncake Store connector. Match the baseline image used in the lab.
FROM docker.io/vllm/vllm-openai-cpu@sha256:827ef38187f9b52f2bb838695ef815ec5b65f4bf3e4c061b002b2b0a19cb0701
USER root
ARG DEBIAN_FRONTEND=noninteractive
ARG MOONCAKE_COMMIT=f7baeb138db8f14bb158e9fc6c84d1a1bd6178f6
ARG BUILD_JOBS=2
RUN apt-get update && apt-get install -y --no-install-recommends \
      git ca-certificates curl ibverbs-utils rdma-core iproute2 \
    && rm -rf /var/lib/apt/lists/*
RUN git init /opt/Mooncake \
    && git -C /opt/Mooncake remote add origin https://github.com/kvcache-ai/Mooncake.git \
    && git -C /opt/Mooncake fetch --depth 1 origin "${MOONCAKE_COMMIT}" \
    && git -C /opt/Mooncake checkout --detach FETCH_HEAD \
    && test "$(git -C /opt/Mooncake rev-parse HEAD)" = "${MOONCAKE_COMMIT}"
WORKDIR /opt/Mooncake
RUN bash dependencies.sh --yes
RUN CMAKE_BUILD_PARALLEL_LEVEL="${BUILD_JOBS}" \
    CMAKE_ARGS="-DWITH_STORE=ON -DWITH_TE=ON -DUSE_CUDA=OFF -DUSE_VRAM_SEGMENT=OFF -DWITH_EP=OFF -DWITH_STORE_GO=OFF -DWITH_STORE_RUST=OFF -DUSE_ETCD=OFF -DSTORE_USE_ETCD=OFF -DSTORE_USE_REDIS=OFF -DSTORE_USE_K8S_LEASE=OFF -DUSE_REDIS=OFF -DUSE_HTTP=ON -DUSE_TCP=ON -DBUILD_UNIT_TESTS=OFF -DBUILD_BENCHMARK=OFF -DBUILD_EXAMPLES=OFF" \
    python3 -m pip install --no-cache-dir --no-deps . \
    && python3 -m pip install --no-cache-dir aiohttp msgpack requests
COPY preflight.py /opt/integration/preflight.py
RUN python3 /opt/integration/preflight.py
ENV PYTHONHASHSEED=0
WORKDIR /opt/integration
ENTRYPOINT ["/bin/bash", "-ec"]
CMD ["exec vllm serve --help"]
