FROM rust:1.99.1-bookworm@sha256:54f6fda5fe78e39d6fbd5796079df987b6af5c4ee19ece84fdf9c6f0635f3e12 AS rust
FROM ubuntu:24.04
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential pkg-config libgtk-4-dev ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=rust /usr/local/rustup /usr/local/rustup
COPY --from=rust /usr/local/cargo /usr/local/cargo
ENV RUSTUP_HOME=/usr/local/rustup CARGO_HOME=/usr/local/cargo PATH=/usr/local/cargo/bin:$PATH
