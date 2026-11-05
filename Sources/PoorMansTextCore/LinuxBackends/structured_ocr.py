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



def refining_options(languages, models, options_class, state):
    import math
    from typing import ClassVar, Literal
    from docling.datamodel.pipeline_options import OcrMode
    from PIL import ImageOps
    import numpy
    from rapidocr import RapidOCR
    from docling.models.stages.ocr.tesseract_ocr_cli_model import TesseractOcrCliModel
    from docling.models.factories import get_ocr_factory

    class RefinedOptions(options_class):
        kind: ClassVar[Literal['pmt_refined_words']] = 'pmt_refined_words'

    class RefinedOCR(TesseractOcrCliModel):
        @classmethod
        def get_options_type(cls):
            return RefinedOptions

        def __init__(self, *args, **kwargs):
            super().__init__(*args, **kwargs)
            self.reader = RapidOCR(params={
                'Global.log_level': 'warning', 'Global.use_det': False, 'Global.use_cls': False,
                'Det.model_path': str(models / 'PP-OCRv6_det_small.onnx'),
                'Rec.model_path': str(models / 'PP-OCRv6_rec_small.onnx'),
                'Cls.model_path': str(models / 'ch_ppocr_mobile_v2.0_cls_mobile.onnx'),
                'EngineConfig.onnxruntime.intra_op_num_threads': 2,
                'EngineConfig.onnxruntime.inter_op_num_threads': 2,
            })

        def post_process_cells(self, cells, page, conv_res):
            scale = min(self.scale, (MAX_PIXELS / (page.size.width * page.size.height)) ** .5)
            full = page._backend.get_page_image(scale=scale).convert('RGB')
            if full.width * full.height > MAX_PIXELS:
                raise ValueError('word refinement raster pixel limit')
            x_scale, y_scale = full.width / page.size.width, full.height / page.size.height
            for cell in cells:
                box = cell.rect.to_bounding_box().to_top_left_origin(page_height=page.size.height)
                values = (box.l * x_scale, box.t * y_scale, box.r * x_scale, box.b * y_scale)
                if not all(math.isfinite(value) for value in values):
                    raise ValueError('invalid word refinement geometry')
                left, top = max(0, round(values[0])), max(0, round(values[1]))
                right, bottom = min(full.width, round(values[2])), min(full.height, round(values[3]))
                if right <= left or bottom <= top:
                    continue
                image = ImageOps.expand(full.crop((left, top, right, bottom)), border=4, fill='white')
                result = self.reader(numpy.asarray(image), use_det=False, use_cls=False, use_rec=True)
                if not result.txts or len(result.txts) != 1 or not math.isfinite(float(result.scores[0])) or float(result.scores[0]) < .99:
                    continue
                candidate = result.txts[0]
                # Der Modellscore ist keine kalibrierte Fehlerwahrscheinlichkeit.
                # Satzzeichen, Abstände und Quellgeometrie werden nicht umgeschrieben.
                punctuation = lambda text: ''.join(char for char in text if not char.isalnum())
                if punctuation(cell.text) != punctuation(candidate):
                    continue
                if cell.text != candidate:
                    state["refinedWordCount"] += 1
                    cell.text = cell.orig = candidate
            return super().post_process_cells(cells, page, conv_res)

    get_ocr_factory(allow_external_plugins=False).register(RefinedOCR, 'pmt-bundled', __name__)
    return RefinedOptions(lang=languages, mode=OcrMode.FULL_PAGE)


def main():
    if len(sys.argv) not in (5, 6) or (len(sys.argv) == 6 and sys.argv[5] != "--refine-words"):
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
    refinement = {"refinedWordCount": 0}
    if len(sys.argv) == 6 and set(languages) <= {"eng", "deu"}:
        try:
            options.ocr_options = refining_options(languages, runtime / "lib/python3.12/site-packages/rapidocr/models", TesseractCliOcrOptions, refinement)
        except ImportError as error:
            print("Local word refinement runtime is unavailable: " + str(error), file=sys.stderr)
            return 69
    else:
        options.ocr_options = TesseractCliOcrOptions(lang=languages, mode=OcrMode.FULL_PAGE)
        if len(sys.argv) == 6:
            refinement["refinementSkippedReason"] = "Word refinement is qualified only for English and German; the selected Tesseract languages were retained."
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
    binding = dict(sourceSHA256=before, width=width, height=height, documentSHA256=hashlib.sha256(data).hexdigest(), **refinement)
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
