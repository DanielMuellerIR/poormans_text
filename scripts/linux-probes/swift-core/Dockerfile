FROM swift:6.2.1-noble
RUN apt-get update && apt-get install -y --no-install-recommends pandoc libz-dev ca-certificates && rm -rf /var/lib/apt/lists/*
WORKDIR /probe
