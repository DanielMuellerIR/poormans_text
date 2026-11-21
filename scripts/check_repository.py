"""Prüft Checkout-Pfade und die Referenzen der GitHub-Workflows."""

import os
from pathlib import Path
import re
import subprocess
import sys
import unicodedata

import yaml


def path_collisions():
    known_paths = {}
    paths = subprocess.check_output(['git', 'ls-files', '-z']).split(b'\0')
    for raw_path in filter(None, paths):
        path = Path(os.fsdecode(raw_path))
        for item in (path, *path.parents):
            key = unicodedata.normalize('NFC', str(item).casefold())
            previous = known_paths.setdefault(key, item)
            if previous != item:
                yield f'Checkout path collision: {previous} and {item}'
                break


def unpinned_actions():
    workflow_directory = Path('.github/workflows')
    for workflow in sorted(workflow_directory.iterdir()):
        if workflow.suffix not in {'.yml', '.yaml'}:
            continue
        data = yaml.safe_load(workflow.read_text(encoding='utf-8'))
        for job in data['jobs'].values():
            for entry in (job, *job.get('steps', [])):
                action = entry.get('uses')
                if action is None or action.startswith('./'):
                    continue
                pin = r'@sha256:[0-9a-f]{64}$' if action.startswith('docker://') else r'@[0-9a-f]{40}$'
                if not re.search(pin, action):
                    yield f'{workflow}: Unpinned action {action}'


def main():
    failures = sorted(set(path_collisions()) | set(unpinned_actions()))
    for failure in failures:
        print(failure, file=sys.stderr)
    return int(bool(failures))


if __name__ == '__main__':
    sys.exit(main())
