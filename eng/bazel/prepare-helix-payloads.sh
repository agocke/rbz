#!/usr/bin/env bash
# Prepares Helix payloads from helix manifests produced by `bazel test`.
#
# The helix launcher (eng/helix_library_test.sh.tpl) writes a .manifest file
# for each test to HELIX_MANIFEST_DIR (passed via --test_env).
#
# This script:
#   1. Reads manifests from the specified directory
#   2. Copies the shared testhost as the Helix correlation payload
#   3. For each manifest, packages the test's output directory as a work item
#
# Usage:
#   eng/bazel/prepare-helix-payloads.sh --manifest-dir DIR
#
# Output:
#   artifacts/helix/testhost/     — arm64 testhost directory (correlation payload)
#   artifacts/helix/tests/NAME/   — per-test payload directories

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

HELIX_DIR="$REPO_ROOT/artifacts/helix"
TESTHOST_DIR="$HELIX_DIR/testhost"
TESTS_DIR="$HELIX_DIR/tests"
MANIFEST_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --manifest-dir) MANIFEST_DIR="$2"; shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# Clean previous payloads (but not manifests — they may be inside HELIX_DIR)
rm -rf "$TESTHOST_DIR" "$TESTS_DIR"
mkdir -p "$TESTHOST_DIR" "$TESTS_DIR"

# Get the .NET SDK version
SDK_VERSION=$(python3 -c "
import json
with open('global.json') as f:
    d = json.load(f)
v = d.get('tools', {}).get('dotnet', d.get('sdk', {}).get('version', ''))
print(v)
" 2>/dev/null || echo "")
if [[ -z "$SDK_VERSION" ]]; then
    SDK_VERSION=$(grep 'PRODUCT_VERSION' eng/bazel/version.bzl | head -1 | sed 's/.*"\(.*\)".*/\1/')
fi

echo "==> SDK version: $SDK_VERSION"

# ---------- Find manifests ----------
if [[ -n "$MANIFEST_DIR" && -d "$MANIFEST_DIR" ]]; then
    # Deterministic location: manifests written directly by helix launcher
    manifests=()
    while IFS= read -r -d '' manifest; do
        manifests+=("$manifest")
    done < <(find "$MANIFEST_DIR" -name "*.manifest" -print0 2>/dev/null)
else
    echo "ERROR: --manifest-dir is required. Usage: prepare-helix-payloads.sh --manifest-dir DIR" >&2
    exit 1
fi

if [[ ${#manifests[@]} -eq 0 ]]; then
    echo "ERROR: No manifests found in $MANIFEST_DIR" >&2
    ls "$MANIFEST_DIR" 2>&1 | head -10 >&2
    exit 1
fi

echo "==> Found ${#manifests[@]} test manifests"

# ---------- Step 1: Copy testhost from first manifest ----------
echo "==> Assembling testhost..."

# Read TESTHOST path from the first manifest
source "${manifests[0]}"
if [[ -z "${TESTHOST:-}" || ! -d "$TESTHOST" ]]; then
    echo "ERROR: TESTHOST path not found or not a directory: ${TESTHOST:-}" >&2
    exit 1
fi

# Copy the shared testhost directory as the Helix correlation payload
cp -rL "$TESTHOST/." "$TESTHOST_DIR/"

# Copy xunit console runner into testhost — Helix run.sh references it from
# $HELIX_CORRELATION_PAYLOAD. The runner DLLs are in each test's output dir
# (symlinked by the test rule); grab them from the first test's TEST_DIR.
if [[ -d "$TEST_DIR" ]]; then
    for f in "$TEST_DIR"/xunit.console.* "$TEST_DIR"/xunit.runner.*; do
        [[ -f "$f" ]] && cp -L "$f" "$TESTHOST_DIR/" 2>/dev/null || true
    done
fi
if [[ ! -f "$TESTHOST_DIR/xunit.console.dll" ]]; then
    echo "   WARNING: xunit.console.dll not found in testhost" >&2
fi
echo "   Testhost assembled: $(find "$TESTHOST_DIR" -type f | wc -l) files"

# ---------- Step 2: Package test work items ----------
echo "==> Packaging test payloads..."

test_count=0
for manifest in "${manifests[@]}"; do
    # Source the manifest to get TEST_NAME, TEST_DIR, TESTHOST
    unset TEST_NAME TEST_DIR
    source "$manifest"

    if [[ -z "${TEST_NAME:-}" || -z "${TEST_DIR:-}" ]]; then
        echo "   SKIP: malformed manifest: $manifest"
        continue
    fi

    if [[ ! -d "$TEST_DIR" ]]; then
        echo "   SKIP: $TEST_NAME (TEST_DIR not found: $TEST_DIR)"
        continue
    fi

    work_dir="$TESTS_DIR/$TEST_NAME"
    mkdir -p "$work_dir"

    # Copy test-specific files (DLL, deps, data files)
    # Skip files that are in the testhost (framework assemblies) to save space
    for f in "$TEST_DIR"/*; do
        [[ -f "$f" ]] || continue
        base=$(basename "$f")
        # Skip launcher scripts and Bazel metadata
        case "$base" in
            *.sh|*.bat|*.repo_mapping|*.runfiles_manifest|*.params) continue ;;
        esac
        # Skip xunit runner files (available in testhost)
        case "$base" in
            xunit.console.*|xunit.runner.*) continue ;;
        esac
        # Skip framework assemblies already in testhost
        if [[ -f "$TESTHOST_DIR/shared/Microsoft.NETCore.App/$SDK_VERSION/$base" ]]; then
            continue
        fi
        cp -L "$f" "$work_dir/" 2>/dev/null || true
    done

    # Copy subdirectories (test data)
    for d in "$TEST_DIR"/*/; do
        [[ -d "$d" ]] || continue
        dname=$(basename "$d")
        case "$dname" in
            *.runfiles|ref) continue ;;
        esac
        cp -rL "$d" "$work_dir/" 2>/dev/null || true
    done

    # Generate runtimeconfig if not already present
    if [[ ! -f "$work_dir/$TEST_NAME.runtimeconfig.json" ]]; then
        cat > "$work_dir/$TEST_NAME.runtimeconfig.json" <<EOF
{
  "runtimeOptions": {
    "tfm": "net11.0",
    "framework": {
      "name": "Microsoft.NETCore.App",
      "version": "$SDK_VERSION"
    },
    "configProperties": {
      "System.Runtime.Serialization.EnableUnsafeBinaryFormatterSerialization": false
    }
  }
}
EOF
    fi

    # Generate deps.json if not already present
    if [[ ! -f "$work_dir/$TEST_NAME.deps.json" ]]; then
        cat > "$work_dir/$TEST_NAME.deps.json" <<EOF
{
  "runtimeTarget": { "name": ".NETCoreApp,Version=v11.0" },
  "compilationOptions": {},
  "targets": { ".NETCoreApp,Version=v11.0": {} },
  "libraries": {}
}
EOF
    fi

    # Write Helix run script
    cat > "$work_dir/run.sh" <<'RUNEOF'
#!/usr/bin/env bash
set -eu

DOTNET_DIR="$(mktemp -d)"
cp "$HELIX_CORRELATION_PAYLOAD/dotnet" "$DOTNET_DIR/dotnet"
chmod +x "$DOTNET_DIR/dotnet"

export DOTNET_ROOT="$HELIX_CORRELATION_PAYLOAD"

RUNEOF
    cat >> "$work_dir/run.sh" <<RUNEOF
exec "\$DOTNET_DIR/dotnet" exec \\
  --runtimeconfig $TEST_NAME.runtimeconfig.json \\
  --depsfile $TEST_NAME.deps.json \\
  \$HELIX_CORRELATION_PAYLOAD/xunit.console.dll \\
  $TEST_NAME.dll \\
  -nologo \\
  -notrait "category=failing" \\
  -notrait "category=OuterLoop"
RUNEOF
    chmod +x "$work_dir/run.sh"

    test_count=$((test_count + 1))
done

echo "==> Packaged $test_count test work items"
echo "==> Helix payloads ready at: $HELIX_DIR"
echo "    Testhost: $(du -sh "$TESTHOST_DIR" | cut -f1)"
echo "    Tests:    $(du -sh "$TESTS_DIR" | cut -f1)"

