#!/usr/bin/env bash
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
cd "$root"
export CARGO_TARGET_DIR=${CARGO_TARGET_DIR:-$root/.build/linux-root-native}
cargo test --locked --offline --workspace
PMT_TEST_CLI="$root/poormans-text" PMT_TEST_GUARD="$root/.build/linux-runtime/bin/poormans-text-process-guard" \
  cargo test --locked --offline -p pmt-bridge -- --ignored --skip tests::ui_owner_process --skip tests::pidfd_failure_process
if [[ ${PMT_ISOLATED_DISPLAY:-0} == 1 ]]; then
  : "${DISPLAY:?Use a private Xvfb display}"
  : "${PMT_UI_TEST_ROOT:?Choose an own new temporary test directory}"
  cargo build --locked --offline -p poormans-text-gtk --features ui-self-test
  python3 linux/app/selftest.py --binary "$CARGO_TARGET_DIR/debug/poormans-text-gtk" \
    --cli "$root/poormans-text" --guard "$root/.build/linux-runtime/bin/poormans-text-process-guard" \
    --display "$DISPLAY" --work-directory "$PMT_UI_TEST_ROOT"
fi
