FROM pmt-linux-backend-test
RUN apt-get update && apt-get install -y --no-install-recommends \
    libreoffice-writer python3-uno \
    && rm -rf /var/lib/apt/lists/*
