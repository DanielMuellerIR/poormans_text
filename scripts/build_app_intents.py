#!/usr/bin/env python3
"""Erzeugt und verarbeitet AppIntents-Konstanten vor der Bundle-Signatur."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import tempfile


def output(*arguments):
    return subprocess.check_output(arguments, text=True).strip()


def comparable_metadata(value):
    if isinstance(value, dict):
        result = {key: comparable_metadata(item) for key, item in value.items()}
        # Apple liefert diese Menge zulässiger Eingabetypen in wechselnder
        # Reihenfolge. Parameter-, Enum- und Aktionsreihenfolgen bleiben erhalten.
        if "resolvableInputTypes" in result:
            result["resolvableInputTypes"].sort(key=lambda item: json.dumps(item, sort_keys=True))
        return result
    if isinstance(value, list):
        return [comparable_metadata(item) for item in value]
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary_directory", type=Path)
    parser.add_argument("bundle", type=Path)
    parser.add_argument("configuration", choices=["debug", "release"])
    args = parser.parse_args()
    project = Path(__file__).resolve().parent.parent
    binary_directory = args.binary_directory.resolve()
    architectures = output("/usr/bin/lipo", "-archs", str(binary_directory / "PoorMansTextApp")).split()
    toolchain = Path(output("xcrun", "--find", "swiftc")).parent.parent
    sdk = output("xcrun", "--sdk", "macosx", "--show-sdk-path")
    xcode_version = output("xcodebuild", "-version").split("Build version ", 1)[1].strip()
    source = project / "Sources/PoorMansTextAppSupport/ConvertDocumentIntent.swift"
    destination = args.bundle / "Contents/Resources/Metadata.appintents"
    if destination.exists():
        raise RuntimeError("AppIntents output already exists in the newly built bundle")
    with tempfile.TemporaryDirectory(prefix="appintents-", dir=project / ".build") as temporary:
        root = Path(temporary)
        sources = root / "sources.txt"
        support_sources = sorted(source.parent.glob("*.swift"))
        sources.write_text("".join(str(path) + "\n" for path in support_sources))
        protocols = root / "protocols.json"
        protocols.write_text(json.dumps(["AppIntent", "AppEnum", "AppShortcutsProvider"]))
        identity = json.loads(output("swift", "package", "show-dependencies", "--format", "json"))["identity"]
        baseline = None
        first_metadata = None
        for architecture in architectures:
            if architecture not in ("arm64", "x86_64"):
                raise RuntimeError("Unsupported AppIntents architecture: " + architecture)
            # SwiftBuild liefert diese Nebenprodukte nicht in jeder Toolchain.
            # Der echte Adapter wird deshalb explizit für jede Architektur
            # kompiliert; diese Hilfsobjekte werden niemals ausgeliefert.
            constant_file = root / (architecture + ".swiftconstvalues")
            subprocess.run([
                "xcrun", "swiftc", "-c", "-whole-module-optimization",
                "-o", str(root / (architecture + ".o")), "-parse-as-library",
                "-module-name", "PoorMansTextAppSupport", "-package-name", identity,
                "-swift-version", "6", "-target", architecture + "-apple-macos13.0",
                "-sdk", sdk, "-I", str(binary_directory), "-F", str(binary_directory),
                "-emit-const-values-path", str(constant_file),
                "-const-gather-protocols-list", str(protocols),
                *map(str, support_sources),
            ], check=True)
            constants = [constant_file]
            extracted = [item for path in constants for item in json.loads(path.read_text())]
            if not any(item.get("typeName") == "PoorMansTextAppSupport.ConvertDocumentIntent" for item in extracted):
                raise RuntimeError("Compiler metadata does not contain the conversion intent")
            values = root / (architecture + ".txt")
            values.write_text("".join(str(path) + "\n" for path in constants))
            target = root / architecture
            target.mkdir()
            subprocess.run([
                "xcrun", "appintentsmetadataprocessor", "--output", str(target),
                "--toolchain-dir", str(toolchain), "--module-name", "PoorMansTextAppSupport",
                "--sdk-root", sdk, "--xcode-version", xcode_version,
                "--platform-family", "macOS", "--deployment-target", "13.0",
                "--target-triple", architecture + "-apple-macos13.0",
                "--source-file-list", str(sources), "--swift-const-vals-list", str(values),
            ], check=True)
            metadata = target / "Metadata.appintents"
            files = {str(item.relative_to(metadata)): json.loads(item.read_text()) for item in metadata.rglob("*") if item.is_file()}
            actions = files.get("extract.actionsdata", {}).get("actions", {})
            if "ConvertDocumentIntent" not in actions:
                raise RuntimeError("Apple metadata does not contain the conversion intent")
            comparable = comparable_metadata(files)
            if baseline is not None and comparable != baseline:
                raise RuntimeError("AppIntents metadata differs between architectures")
            if baseline is None:
                baseline = comparable
                first_metadata = metadata
        if first_metadata is None:
            raise RuntimeError("No AppIntents architecture was built")
        shutil.copytree(first_metadata, destination)
    print("APPINTENTS OK: " + ", ".join(architectures))


if __name__ == "__main__":
    main()
