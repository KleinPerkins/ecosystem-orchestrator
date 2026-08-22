#!/usr/bin/env bash
set -euo pipefail

run_test() {
  local test_path="$1"
  local log_file
  log_file="$(mktemp)"
  if bash "$test_path" >"$log_file" 2>&1; then
    printf '%s: OK\n' "$test_path"
    rm -f "$log_file"
    return 0
  fi

  printf '%s: FAILED\n' "$test_path" >&2
  cat "$log_file" >&2
  rm -f "$log_file"
  return 1
}

run_test tests/test_registry_cli.sh
run_test tests/test_plugin_discovery.sh
run_test tests/test_google_kit_payload.sh
run_test tests/test_tool_descriptor_payload.sh
run_test tests/test_tool_snapshot_payload.sh
run_test tests/test_chaos_shim.sh
run_test tests/test_lockkit.sh
run_test tests/test_delete_propagation.sh
run_test tests/test_zero_link.sh
