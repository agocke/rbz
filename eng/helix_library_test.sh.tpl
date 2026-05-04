#!/usr/bin/env bash
# Helix payload packaging launcher for cross-compiled tests.
# Instead of running the test, this script writes a manifest of test file paths
# to $TEST_UNDECLARED_OUTPUTS_DIR. After `bazel test`, a collection script reads
# the manifests from bazel-testlogs/ to assemble Helix payloads.

# --- begin runfiles.bash initialization v3 ---
# Copy-pasted from the Bazel Bash runfiles library v3.
set -uo pipefail; set +e; f=bazel_tools/tools/bash/runfiles/runfiles.bash
source "${RUNFILES_DIR:-/dev/null}/$f" 2>/dev/null || \
  source "$(grep -sm1 "^$f " "${RUNFILES_MANIFEST_FILE:-/dev/null}" | cut -f2- -d' ')" 2>/dev/null || \
  source "$0.runfiles/$f" 2>/dev/null || \
  source "$(grep -sm1 "^$f " "$0.runfiles_manifest" | cut -f2- -d' ')" 2>/dev/null || \
  source "$(grep -sm1 "^$f " "$0.exe.runfiles_manifest" | cut -f2- -d' ')" 2>/dev/null || \
  { echo>&2 "ERROR: cannot find $f"; exit 1; }; f=; set -e
# --- end runfiles.bash initialization v3 ---

TESTHOST_RAW=$(rlocation TEMPLATED_testhost)
ENTRY_DLL="$(rlocation TEMPLATED_entry_dll)"

# Validate resolved paths
if [[ -z "$ENTRY_DLL" || ! -f "$ENTRY_DLL" ]]; then
    echo >&2 "ERROR: ENTRY_DLL not found: $ENTRY_DLL"
    exit 1
fi
if [[ -z "$TESTHOST_RAW" || ! -d "$TESTHOST_RAW" ]]; then
    echo >&2 "ERROR: TESTHOST not found: $TESTHOST_RAW"
    exit 1
fi

# Convert sandbox paths to persistent execroot paths.
# During sandboxed test execution, paths look like:
#   .../sandbox/processwrapper-sandbox/NNN/execroot/_main/bazel-out/...
# The persistent equivalent is:
#   .../execroot/_main/bazel-out/...
# Strip the sandbox prefix to get paths that survive after test cleanup.
make_persistent() {
    local p="$1"
    echo "$p" | sed 's|/sandbox/[^/]*/[0-9]*/execroot/|/execroot/|'
}

TEST_DIR="$(make_persistent "$(cd "$(dirname "$ENTRY_DLL")" && pwd)")"
TESTHOST="$(make_persistent "$(cd "$TESTHOST_RAW" && pwd)")"
TEST_NAME="TEMPLATED_test_name"

# Write manifest to HELIX_MANIFEST_DIR if set (deterministic location),
# otherwise fall back to TEST_UNDECLARED_OUTPUTS_DIR (bazel-testlogs).
if [[ -n "${HELIX_MANIFEST_DIR:-}" ]]; then
    MANIFEST_DIR="$HELIX_MANIFEST_DIR"
elif [[ -n "${TEST_UNDECLARED_OUTPUTS_DIR:-}" ]]; then
    MANIFEST_DIR="$TEST_UNDECLARED_OUTPUTS_DIR"
else
    echo >&2 "ERROR: Neither HELIX_MANIFEST_DIR nor TEST_UNDECLARED_OUTPUTS_DIR set"
    exit 1
fi

mkdir -p "$MANIFEST_DIR"
cat > "$MANIFEST_DIR/${TEST_NAME}.manifest" <<EOF
TEST_NAME=$TEST_NAME
TEST_DIR=$TEST_DIR
TESTHOST=$TESTHOST
EOF

