FROM pmt-linux-package-test
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3-pil python3-gi python3-cairo python3-gi-cairo gir1.2-poppler-0.18 \
    tesseract-ocr tesseract-ocr-deu pandoc qpdf fonts-dejavu-core \
    && rm -rf /var/lib/apt/lists/*
