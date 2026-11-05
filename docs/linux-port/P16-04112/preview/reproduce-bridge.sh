#!/usr/bin/env bash
set -euo pipefail
probe=$(cd -- "$(dirname -- "$0")" && pwd)
repo=${PMT_FINAL_REPO:?set read-only source repository}
target=${PMT_FINAL_CARGO_TARGET:?set explicitly owned generated Cargo target}
cli=${PMT_FINAL_CLI:?set final CLI launcher}
guard=${PMT_FINAL_GUARD:?set final guard}
mkdir -p "$probe/host-temp"
PMT_TEST_CLI="$cli" PMT_TEST_GUARD="$guard" TMPDIR="$probe/host-temp" CARGO_TARGET_DIR="$target" \
 cargo test --manifest-path "$repo/Cargo.toml" --locked --offline -p pmt-bridge -- \
 --ignored --skip tests::ui_owner_process --skip tests::pidfd_failure_process --test-threads=1
