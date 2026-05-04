#!/usr/bin/env bash
# Prepares Helix payloads by collecting manifests from bazel-testlogs/ after
# running `bazel test` with helix launcher templates for cross-compiled tests.
#
# Prerequisites:
#   bazel test //src/libraries/... --platforms=//platforms:linux_arm64 ...
#
# The helix launcher (eng/helix_library_test.sh.tpl) writes a manifest to
# $TEST_UNDECLARED_OUTPUTS_DIR for each test. After `bazel test`, these are
# collected into bazel-testlogs/<target>/test.outputs/helix_manifest.txt.
#
# This script:
#   1. Copies the shared testhost as the Helix correlation payload
#   2. For each manifest, packages the test's output directory as a work item
#
# Usage:
#   eng/bazel/prepare-helix-payloads.sh
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

# Clean previous payloads
rm -rf "$HELIX_DIR"
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

# ---------- Find manifests from bazel-testlogs ----------
TESTLOGS_DIR="$REPO_ROOT/bazel-testlogs"
if [[ ! -d "$TESTLOGS_DIR" ]]; then
    echo "ERROR: bazel-testlogs/ not found. Run 'bazel test' first." >&2
    exit 1
fi

# Debug: show what bazel-testlogs resolves to and sample contents
echo "   bazel-testlogs -> $(readlink -f "$TESTLOGS_DIR" 2>/dev/null || echo "$TESTLOGS_DIR")"
echo "   Top-level contents:"
ls "$TESTLOGS_DIR" 2>/dev/null | head -5 || true
if [[ -d "$TESTLOGS_DIR/src/libraries" ]]; then
    echo "   Sample test dir:"
    find "$TESTLOGS_DIR/src/libraries" -maxdepth 4 -type d | head -5 || true
    echo "   Sample test files:"
    find "$TESTLOGS_DIR/src/libraries" -maxdepth 5 -type f | head -10 || true
fi

# Look for manifests in test.outputs/ directories (undeclared test outputs).
# Bazel places these at: bazel-testlogs/<pkg>/<target>/test.outputs/helix_manifest.txt
manifests=()
while IFS= read -r -d '' manifest; do
    manifests+=("$manifest")
done < <(find "$TESTLOGS_DIR/src/libraries" -path "*/test.outputs/helix_manifest.txt" -print0 2>/dev/null)

# Fallback: check if manifests are anywhere under testlogs
if [[ ${#manifests[@]} -eq 0 ]]; then
    while IFS= read -r -d '' manifest; do
        manifests+=("$manifest")
    done < <(find "$TESTLOGS_DIR" -name "helix_manifest.txt" -print0 2>/dev/null)
fi

# Fallback: extract from outputs.zip files if manifests not found loose
if [[ ${#manifests[@]} -eq 0 ]]; then
    echo "   No loose manifests found, checking for outputs.zip..."
    EXTRACT_DIR="$(mktemp -d)"
    while IFS= read -r -d '' zipfile; do
        target_dir="$(dirname "$zipfile")"
        if unzip -q -o "$zipfile" "helix_manifest.txt" -d "$target_dir" 2>/dev/null; then
            manifests+=("$target_dir/helix_manifest.txt")
        fi
    done < <(find "$TESTLOGS_DIR" -name "outputs.zip" -print0 2>/dev/null)
    echo "   Found ${#manifests[@]} manifests in zip files"
fi

if [[ ${#manifests[@]} -eq 0 ]]; then
    echo "ERROR: No helix manifests found in bazel-testlogs/." >&2
    echo "   Searched: $TESTLOGS_DIR" >&2
    echo "   All files in testlogs (first 20):" >&2
    find "$TESTLOGS_DIR" -type f 2>/dev/null | head -20 >&2 || true
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

