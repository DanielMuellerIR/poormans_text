FROM swift:6.2.1-noble
RUN apt-get update && apt-get install -y --no-install-recommends \
    libpng-dev zlib1g-dev pandoc zip python3-minimal bubblewrap \
    && rm -rf /var/lib/apt/lists/*
