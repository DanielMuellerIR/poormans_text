#!/usr/bin/env python3
"""Prüft den echten Linux-CLI-Build mit synthetischen, unveränderten Quellen."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("cli", type=Path)
parser.add_argument("--pandoc", required=True, type=Path)
args = parser.parse_args()
cli = args.cli.resolve()
pandoc = args.pandoc.resolve()
scripts = Path(__file__).resolve().parent
repo = scripts.parent.parent


def convert(root, source, destination, tool=pandoc, extra=()):
    return subprocess.run(
        [str(cli), "--json", "--report", "--source-map", "--pandoc", str(tool),
         *extra, "--output", str(destination), "--", str(source)],
        capture_output=True, timeout=15,
    )


with tempfile.TemporaryDirectory(prefix="pmt-linux-product-") as temporary:
    root = Path(temporary)
    shutil.copy2(scripts / "swift-core/fixtures.py", root / "fixtures.py")
    subprocess.run(["python3", str(root / "fixtures.py")], check=True)
    fixtures = root / "fixtures"
    shutil.copy2(repo / "Tests/PoorMansTextCoreTests/Fixtures/WordProcessing/fixture.png",
                 fixtures / "fixture.png")
    subprocess.run([str(pandoc), "picture.md", "-o", "picture.docx"], cwd=fixtures, check=True)
    sources = ["table.csv", "table.xlsx", "notebook.ipynb", "picture.docx", "encoding.rtf"]
    hashes = {name: hashlib.sha256((fixtures / name).read_bytes()).hexdigest() for name in sources}
    (fixtures / "source-hashes.json").write_text(json.dumps(hashes), encoding="utf-8")
    output = root / "output"
    output.mkdir()
    for name in sources:
        result = convert(root, fixtures / name, output / name)
        assert result.returncode == 0, (name, result.returncode, result.stdout, result.stderr)
        response = json.loads(result.stdout)
        assert response["ok"]
        for entry in response["outputFiles"]:
            assert hashlib.sha256((output / name / entry["path"]).read_bytes()).hexdigest() == entry["sha256"]
    subprocess.run(["python3", str(scripts / "swift-core/verify.py"), str(root), str(output)], check=True)

    collision = convert(root, fixtures / "table.csv", output / "table.csv")
    assert collision.returncode != 0 and not json.loads(collision.stdout)["ok"]
    assert hashlib.sha256((fixtures / "table.csv").read_bytes()).hexdigest() == hashes["table.csv"]

    slow = root / "slow-pandoc"
    slow.write_text('#!/bin/sh\ntrap "" TERM\nsleep 60 &\nwait\n', encoding="utf-8")
    slow.chmod(0o755)
    timeout = convert(root, fixtures / "encoding.rtf", root / "timeout", slow, ["--timeout", "0.15"])
    assert timeout.returncode == 124 and not (root / "timeout").exists(), timeout.stdout
    process = subprocess.Popen(
        [str(cli), "--json", "--pandoc", str(slow), "--output", str(root / "cancel"),
         "--", str(fixtures / "encoding.rtf")], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    try:
        time.sleep(0.3)
        process.send_signal(signal.SIGTERM)
        stdout, _ = process.communicate(timeout=10)
        assert process.returncode == 130 and not (root / "cancel").exists(), stdout
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
    invalid = subprocess.run([os.fsencode(cli), b"--json", b"--", b"/tmp/pmt-invalid-\xff.csv"],
                             capture_output=True, timeout=5)
    assert invalid.returncode == 64 and not json.loads(invalid.stdout)["ok"]
    print("Product CLI: 5 conversions, output hashes, collision, timeout, SIGTERM, invalid UTF-8 PASS")
