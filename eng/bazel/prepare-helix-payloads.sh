#!/usr/bin/env bash
# Prepares Helix payloads from Bazel build outputs for arm64 testing.
#
# This script assembles:
#   1. An arm64 testhost (correlation payload) from Bazel-built arm64 binaries
#   2. Per-test work item directories from Bazel-built test outputs
#
# Prerequisites:
#   - Bazel arm64 build completed (native + managed source targets)
#   - Bazel x64 build completed (test targets — managed DLLs are arch-independent)
#
# Usage:
#   eng/bazel/prepare-helix-payloads.sh [--config release|checked] [--test-filter PATTERN]
#
# Output:
#   artifacts/helix/testhost/     — arm64 testhost directory
#   artifacts/helix/tests/NAME/   — per-test payload directories

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

# ---------- Parse arguments ----------
config="clr_release"
bazel_config_flags="--config=clr_release --config=libs_release"
test_filter=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --config)
            config="$2"
            bazel_config_flags="--config=$2"
            shift 2
            ;;
        --bazel-config)
            # Allow passing full config flags (e.g., "--config=clr_release --config=libs_release")
            bazel_config_flags="$2"
            shift 2
            ;;
        --test-filter)
            test_filter="$2"
            shift 2
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

HELIX_DIR="$REPO_ROOT/artifacts/helix"
TESTHOST_DIR="$HELIX_DIR/testhost"
TESTS_DIR="$HELIX_DIR/tests"

# Clean previous payloads
rm -rf "$HELIX_DIR"
mkdir -p "$TESTHOST_DIR" "$TESTS_DIR"

# ---------- Helper: resolve Bazel output path ----------
# Uses bazel cquery to find the actual output file path for a target.
bazel_output() {
    local platform_flags="$1"
    local target="$2"
    bazel cquery $platform_flags $bazel_config_flags --output=files "$target" 2>/dev/null
}

# ---------- Step 1: Assemble arm64 testhost ----------
echo "==> Assembling arm64 testhost..."

ARM64_FLAGS="--platforms=//platforms:linux_arm64"

# Get the .NET SDK version from the dotnet toolchain
SDK_VERSION=$(python3 -c "
import json, sys
with open('global.json') as f:
    d = json.load(f)
# Use the runtime version from the SDK version
v = d.get('tools', {}).get('dotnet', d.get('sdk', {}).get('version', ''))
print(v)
" 2>/dev/null || echo "")

# Fall back to reading from version.bzl
if [[ -z "$SDK_VERSION" ]]; then
    SDK_VERSION=$(grep 'PRODUCT_VERSION' eng/bazel/version.bzl | head -1 | sed 's/.*"\(.*\)".*/\1/')
fi
echo "   SDK version: $SDK_VERSION"

FW_DIR="$TESTHOST_DIR/shared/Microsoft.NETCore.App/$SDK_VERSION"
FXR_DIR="$TESTHOST_DIR/host/fxr/$SDK_VERSION"
mkdir -p "$FW_DIR" "$FXR_DIR"

# Copy arm64 native binaries
echo "   Copying arm64 native binaries..."
DOTNET_PATH=$(bazel_output "$ARM64_FLAGS" "//src/native/corehost:dotnet")
cp -L "$DOTNET_PATH" "$TESTHOST_DIR/dotnet"
chmod +x "$TESTHOST_DIR/dotnet"

HOSTFXR_PATH=$(bazel_output "$ARM64_FLAGS" "//src/native/corehost:hostfxr")
cp -L "$HOSTFXR_PATH" "$FXR_DIR/"
cp -L "$HOSTFXR_PATH" "$FW_DIR/"

HOSTPOLICY_PATH=$(bazel_output "$ARM64_FLAGS" "//src/native/corehost:hostpolicy")
cp -L "$HOSTPOLICY_PATH" "$FW_DIR/"

CORECLR_PATH=$(bazel_output "$ARM64_FLAGS" "//src/coreclr/dlls/mscoree/coreclr:libcoreclr.so")
cp -L "$CORECLR_PATH" "$FW_DIR/"

CLRJIT_PATH=$(bazel_output "$ARM64_FLAGS" "//src/coreclr/jit:libclrjit.so")
cp -L "$CLRJIT_PATH" "$FW_DIR/"

# Copy arm64 native shared libraries
for lib_so in $(bazel_output "$ARM64_FLAGS" 'kind("cc_shared_library", //src/native/libs/...)'); do
    cp -L "$lib_so" "$FW_DIR/"
done

# Copy managed assemblies (arch-independent, use arm64 build outputs)
echo "   Copying managed assemblies..."
# System.Private.CoreLib (non-crossgen'd version for arm64)
CORELIB_PATH=$(bazel_output "$ARM64_FLAGS" "//src/coreclr/System.Private.CoreLib:impl_System.Private.CoreLib")
if [[ -n "$CORELIB_PATH" && -f "$CORELIB_PATH" ]]; then
    cp -L "$CORELIB_PATH" "$FW_DIR/System.Private.CoreLib.dll"
fi

# All impl_netcoreapp managed assemblies
# These are the live-built library DLLs that form the shared framework.
for dll in $(bazel_output "$ARM64_FLAGS" "//src/libraries:impl_netcoreapp" 2>/dev/null || true); do
    if [[ -f "$dll" && "$dll" == *.dll ]]; then
        cp -L "$dll" "$FW_DIR/"
    fi
done

# Generate a version-free deps.json for the testhost
echo "   Generating testhost deps.json..."
{
    printf '{"runtimeTarget":{"name":".NETCoreApp,Version=v0.0/rid","signature":""},'
    printf '"compilationOptions":{},"targets":{".NETCoreApp,Version=v0.0":{},'
    printf '".NETCoreApp,Version=v0.0/rid":{"Microsoft.NETCore.App/%s":{"runtime":{' "$SDK_VERSION"
    first=true
    for dll in "$FW_DIR"/*.dll; do
        [ -f "$dll" ] || continue
        base=$(basename "$dll")
        if $first; then first=false; else printf ','; fi
        printf '"runtimes/rid/lib/netcoreapp0.0/%s":{}' "$base"
    done
    printf '},"native":{'
    first=true
    for native in "$FW_DIR"/*.so; do
        [ -f "$native" ] || continue
        base=$(basename "$native")
        if $first; then first=false; else printf ','; fi
        printf '"runtimes/rid/native/%s":{}' "$base"
    done
    printf '}}}},"libraries":{"Microsoft.NETCore.App/%s":{"type":"package","serviceable":false,"sha512":""}}}' "$SDK_VERSION"
} > "$FW_DIR/Microsoft.NETCore.App.deps.json"

echo "   Testhost assembled: $(find "$TESTHOST_DIR" -type f | wc -l) files"

# ---------- Step 2: Copy xunit runner to testhost (for Helix command) ----------
echo "==> Copying xunit runner..."
# xunit.console.dll needs to be in the correlation payload so Helix can find it.
# The runner comes from a NuGet package, resolved via bazel cquery.
# Output paths are relative to the execution root; resolve via bazel-<workspace>/
EXEC_ROOT="$REPO_ROOT/$(basename "$REPO_ROOT" | sed 's/^/bazel-/')"
for f in $(bazel cquery --output=files "//eng:xunit_console_runner" 2>/dev/null || true); do
    abs_path="$EXEC_ROOT/$f"
    if [[ -f "$abs_path" ]]; then
        cp -L "$abs_path" "$TESTHOST_DIR/"
    fi
done
if [[ ! -f "$TESTHOST_DIR/xunit.console.dll" ]]; then
    echo "   WARNING: xunit.console.dll not found in testhost" >&2
fi

# ---------- Step 3: Package test work items ----------
echo "==> Packaging test payloads..."

# Find all library test targets
if [[ -n "$test_filter" ]]; then
    test_query="kind(test, //src/libraries/$test_filter/...)"
else
    test_query="kind(test, //src/libraries/...)"
fi

# Get list of test targets
test_targets=$(bazel query "$test_query" 2>/dev/null || true)
test_count=0

for target in $test_targets; do
    # Extract test name from target label (e.g., //src/libraries/System.Runtime/tests:System.Runtime.Tests)
    test_name="${target##*:}"

    # Find the test DLL output path via cquery
    dll_path=$(bazel cquery $bazel_config_flags --output=files "$target" 2>/dev/null | head -1)
    if [[ -z "$dll_path" ]]; then
        echo "   SKIP: $test_name (cquery failed)"
        continue
    fi

    # Resolve to absolute path: cquery returns paths relative to execution root
    if [[ "$dll_path" == bazel-out/* ]]; then
        abs_dll="$REPO_ROOT/$dll_path"
    else
        abs_dll="$EXEC_ROOT/$dll_path"
    fi

    if [[ ! -f "$abs_dll" ]]; then
        echo "   SKIP: $test_name (DLL not built: $abs_dll)"
        continue
    fi

    # The test output directory contains the DLL + all deps + runtimeconfig + deps.json
    test_out_dir=$(dirname "$abs_dll")

    # Create per-test work item directory
    work_dir="$TESTS_DIR/$test_name"
    mkdir -p "$work_dir"

    # Copy all files from the test output directory, skipping:
    # - Framework assemblies (already in testhost)
    # - Bazel launcher/runfiles artifacts
    # - PDB files (optional, skip to reduce payload size)
    for f in "$test_out_dir"/*; do
        [[ -f "$f" ]] || continue
        base=$(basename "$f")
        # Skip Bazel-generated launcher/runfiles artifacts
        case "$base" in
            *.sh|*.bat|*.repo_mapping|*.runfiles_manifest|*.params) continue ;;
        esac
        # Skip xunit runner files (already in testhost correlation payload)
        case "$base" in
            xunit.console.*|xunit.runner.*) continue ;;
        esac
        # Skip framework assemblies that are already in the testhost
        if [[ -f "$FW_DIR/$base" ]]; then
            continue
        fi
        cp -L "$f" "$work_dir/" 2>/dev/null || true
    done

    # Copy data subdirectories (test data files)
    for d in "$test_out_dir"/*/; do
        [[ -d "$d" ]] || continue
        dname=$(basename "$d")
        # Skip Bazel runfiles directory and ref assemblies
        case "$dname" in
            *.runfiles|ref) continue ;;
        esac
        cp -rL "$d" "$work_dir/" 2>/dev/null || true
    done

    # Ensure we have runtimeconfig.json (generate if missing)
    if [[ ! -f "$work_dir/$test_name.runtimeconfig.json" ]]; then
        cat > "$work_dir/$test_name.runtimeconfig.json" <<EOF
{
  "runtimeOptions": {
    "tfm": "net10.0",
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

    # Ensure we have deps.json (generate minimal if missing)
    if [[ ! -f "$work_dir/$test_name.deps.json" ]]; then
        cat > "$work_dir/$test_name.deps.json" <<EOF
{
  "runtimeTarget": { "name": ".NETCoreApp,Version=v10.0" },
  "compilationOptions": {},
  "targets": { ".NETCoreApp,Version=v10.0": {} },
  "libraries": {}
}
EOF
    fi

    # Generate run.sh wrapper for Helix execution
    cat > "$work_dir/run.sh" <<'RUNEOF'
#!/usr/bin/env bash
set -eu

# The correlation payload may be on a read-only filesystem.
# Copy the dotnet host to a writable location and make it executable.
DOTNET_DIR="$(mktemp -d)"
cp "$HELIX_CORRELATION_PAYLOAD/dotnet" "$DOTNET_DIR/dotnet"
chmod +x "$DOTNET_DIR/dotnet"

# Set up the runtime to find the shared framework from the correlation payload
export DOTNET_ROOT="$HELIX_CORRELATION_PAYLOAD"

RUNEOF
    # Append the test-specific exec line (needs variable expansion for test name)
    cat >> "$work_dir/run.sh" <<RUNEOF
exec "\$DOTNET_DIR/dotnet" exec \\
  --runtimeconfig $test_name.runtimeconfig.json \\
  --depsfile $test_name.deps.json \\
  \$HELIX_CORRELATION_PAYLOAD/xunit.console.dll \\
  $test_name.dll \\
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
