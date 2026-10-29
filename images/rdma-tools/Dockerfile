FROM ubuntu:24.04
ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates iproute2 iputils-ping ethtool rdma-core ibverbs-utils \
      perftest procps util-linux \
    && rm -rf /var/lib/apt/lists/*
CMD ["sleep", "infinity"]
