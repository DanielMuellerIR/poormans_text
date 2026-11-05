FROM ubuntu:24.04
RUN apt-get update && apt-get install -y --no-install-recommends \
    bubblewrap libstdc++6 python3 util-linux \
    && rm -rf /var/lib/apt/lists/*
