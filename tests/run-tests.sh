#!/usr/bin/env bash
set -euo pipefail

bash tests/test_registry_cli.sh
bash tests/test_plugin_discovery.sh
bash tests/test_google_kit_payload.sh
bash tests/test_tool_descriptor_payload.sh
bash tests/test_tool_snapshot_payload.sh
bash tests/test_chaos_shim.sh
bash tests/test_lockkit.sh
bash tests/test_delete_propagation.sh
printf 'PR_AUTOMATION_VERIFY_OK\n'
