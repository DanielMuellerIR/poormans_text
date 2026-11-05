"""Nur typisierte Docling-Daten eines gebundenen PNG; kein Markdownexport."""
import os
import resource
import sys
sys.dont_write_bytecode = True

# Vor Torch-/Bildparserimporten: auch native Worker erben die festen Grenzen.
resource.setrlimit(resource.RLIMIT_AS, (4 * 1024**3, 4 * 1024**3))
resource.setrlimit(resource.RLIMIT_CPU, (120, 120))
resource.setrlimit(resource.RLIMIT_FSIZE, (8 * 1024**2, 8 * 1024**2))
for key, value in {
    "HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1", "HF_DATASETS_OFFLINE": "1",
    "HF_HUB_DISABLE_TELEMETRY": "1", "DO_NOT_TRACK": "1", "TOKENIZERS_PARALLELISM": "false",
    "OMP_NUM_THREADS": "2", "OPENBLAS_NUM_THREADS": "2", "MKL_NUM_THREADS": "2",
    "NUMEXPR_NUM_THREADS": "2", "HOME": "/tmp", "XDG_CACHE_HOME": "/tmp/cache",
    "HF_HOME": "/tmp/huggingface", "TORCH_HOME": "/tmp/torch",
}.items():
    os.environ[key] = value

import hashlib
import json
import re
from pathlib import Path

MAX_JSON = 8 * 1024**2
MAX_PIXELS = 16_000_000


def main():
    if len(sys.argv) != 5:
        raise ValueError("invalid structured OCR invocation")
    runtime, source, languages, destination = Path(sys.argv[1]), Path(sys.argv[2]), json.loads(sys.argv[3]), Path(sys.argv[4])
    if not isinstance(languages, list) or not 1 <= len(languages) <= 8 or any(not isinstance(x, str) or not re.fullmatch(r"[A-Za-z0-9_-]{1,64}", x) for x in languages):
        raise ValueError("invalid installed OCR language selection")
    if source.stat().st_size > 256 * 1024**2:
        raise ValueError("structured OCR raster byte limit")
    before = hashlib.file_digest(source.open("rb"), "sha256").hexdigest()
    try:
        from PIL import Image
        Image.MAX_IMAGE_PIXELS = MAX_PIXELS
        with Image.open(source) as image:
            if image.format != "PNG" or image.width <= 0 or image.height <= 0 or image.width * image.height > MAX_PIXELS or getattr(image, "n_frames", 1) != 1:
                raise ValueError("invalid single PNG raster")
            width, height = image.size
            dpi = image.info.get("dpi")
            image.verify()
        import torch
        from docling.datamodel.accelerator_options import AcceleratorDevice, AcceleratorOptions
        from docling.datamodel.base_models import InputFormat, ConversionStatus
        from docling.datamodel.pipeline_options import PdfPipelineOptions, LayoutObjectDetectionOptions, TableStructureOptions, TableFormerMode, TesseractCliOcrOptions, OcrMode
        from docling.document_converter import DocumentConverter, ImageFormatOption
    except (ImportError, ModuleNotFoundError) as error:
        print("Local structured OCR runtime is unavailable: " + str(error), file=sys.stderr)
        return 69
    models = runtime / "models"
    if not (models / "docling-project--docling-layout-heron").is_dir() or not (models / "docling-project--docling-models/model_artifacts/tableformer/accurate").is_dir():
        print("Local structured OCR model data is unavailable.", file=sys.stderr)
        return 69
    torch.set_num_threads(2)
    torch.set_num_interop_threads(1)
    layout = LayoutObjectDetectionOptions.from_preset("layout_heron_default")
    layout.model_spec = layout.model_spec.model_copy(update={"revision": "8f39ad3c0b4c58e9c2d2c84a38465abf757272d8"})
    options = PdfPipelineOptions(artifacts_path=models)
    options.accelerator_options = AcceleratorOptions(device=AcceleratorDevice.CPU, num_threads=2)
    options.layout_options = layout
    options.do_table_structure = True
    options.table_structure_options = TableStructureOptions(mode=TableFormerMode.ACCURATE, do_cell_matching=True)
    options.do_ocr = True
    options.ocr_options = TesseractCliOcrOptions(lang=languages, mode=OcrMode.FULL_PAGE)
    options.enable_remote_services = False
    converter = DocumentConverter(allowed_formats=[InputFormat.IMAGE], format_options={InputFormat.IMAGE: ImageFormatOption(pipeline_options=options)})
    result = converter.convert(source, max_num_pages=1, max_file_size=256 * 1024**2)
    if result.status != ConversionStatus.SUCCESS:
        raise ValueError("structured OCR did not produce a complete document")
    document = result.document.export_to_dict()
    data = json.dumps(document, ensure_ascii=False, allow_nan=False, separators=(",", ":")).encode("utf-8")
    if len(data) > MAX_JSON:
        raise ValueError("structured OCR JSON byte limit")
    if hashlib.file_digest(source.open("rb"), "sha256").hexdigest() != before:
        raise ValueError("structured OCR raster changed")
    with destination.open("xb") as output:
        output.write(data)
    binding = dict(sourceSHA256=before, width=width, height=height, documentSHA256=hashlib.sha256(data).hexdigest())
    if dpi is not None:
        binding.update(dpiX=float(dpi[0]), dpiY=float(dpi[1]))
    print(json.dumps(binding, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except FileNotFoundError as error:
        print("Local structured OCR resource is unavailable: " + str(error), file=sys.stderr)
        sys.exit(69)
    except Exception as error:
        print("Local structured OCR failed: " + str(error), file=sys.stderr)
        sys.exit(70)
