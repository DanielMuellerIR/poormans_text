import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

cli, fixture_dir = map(Path, sys.argv[1:])
fixtures = sorted(p for p in fixture_dir.glob("*.pdf") if p.stem in {"0", "90", "180", "270"})
assert len(fixtures) == 4
mask = fixture_dir / "shared-mask.json"

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def extract(output):
    result = subprocess.run([str(cli), "extract", "--mask", str(mask), "--output-dir",
                             str(output), *map(str, fixtures)], capture_output=True, text=True, timeout=30)
    return result.returncode, json.loads(result.stdout)

originals = {p: sha(p) for p in [mask, *fixtures]}
with tempfile.TemporaryDirectory(prefix="pmt-candidate-receipts-") as temp:
    destination = Path(temp)
    code, summary = extract(destination)
    assert code == 1 and len(summary["items"]) == len(fixtures), summary
    assert all(item["status"] == "reviewRequired" for item in summary["items"]), summary
    results = {}
    snapshots = {}
    for file in fixtures:
        output = destination / (file.name + ".json")
        row = json.loads(output.read_text())
        assert row["data"] == {"Column": "LEFT ALPHA\nLEFT BRAVO", "Number": "NW-4711", "Date": None, "Missing": None}, row["data"]
        names = {field: data["status"] for field, data in row["review"].items()}
        assert names == {"Column":"confirmed", "Number":"confirmed", "Date":"ambiguous", "Missing":"missing"}
        results[file.name] = {
            "inputSHA256": originals[file],
            "fields": row["data"],
            "review": names,
        }
        snapshots[output] = sha(output)
    failure, repeated = extract(destination)
    assert failure == 1 and len(repeated["items"]) == len(fixtures)
    assert all(r["status"] == "failed" and ("already in use" in r.get("diagnostic", "")) for r in repeated["items"]), repeated
    assert all(sha(p) == original for p, original in {**originals, **snapshots}.items())
    evidence = {"version": subprocess.check_output([str(cli), "--version"], text=True).strip(),
                "maskSHA256": originals[mask], "records": results, "existingOutputsProtected": True,
                "sourcesProtected": True}
    print(json.dumps(evidence, ensure_ascii=False, indent=2, sort_keys=True))
