#!/usr/bin/env bash
# compare-bazel.sh — Compare Bazel and CMake/MSBuild build inputs
#
# Verifies that the Bazel build compiles the same source files with the same
# compiler options as the CMake/MSBuild build.  Compares both native C/C++
# (via compile_commands.json vs bazel aquery) and managed C# (via .binlog vs
# bazel aquery).
#
# Usage:
#   ./compare-bazel.sh                    # Release config, x64 arch (default)
#   ./compare-bazel.sh --arch arm64       # Release config, arm64 arch
#   ./compare-bazel.sh --config release   # Release config
#   ./compare-bazel.sh --config both      # Both configs
#   ./compare-bazel.sh --skip-build       # Use existing build artifacts
#   ./compare-bazel.sh --verbose          # Show all differences
#   ./compare-bazel.sh --json-output report.json

set -euo pipefail

scriptroot="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ----- Defaults -----
config="release"
arch="x64"
skip_build=false
verbose=false
json_output=""
msbuild_json=""

# ----- Parse arguments -----
while [[ $# -gt 0 ]]; do
    case "$1" in
        --config)
            config="${2,,}"
            shift 2
            ;;
        --arch)
            arch="${2,,}"
            shift 2
            ;;
        --skip-build)
            skip_build=true
            shift
            ;;
        --verbose|-v)
            verbose=true
            shift
            ;;
        --json-output)
            json_output="$2"
            shift 2
            ;;
        --msbuild-json)
            msbuild_json="$2"
            shift 2
            ;;
        -h|--help)
            head -17 "${BASH_SOURCE[0]}" | tail -16
            exit 0
            ;;
        *)
            echo "Unknown argument: $1"
            exit 1
            ;;
    esac
done

# Validate arch
case "$arch" in
    x64|arm64) ;;
    *)
        echo "Invalid arch: $arch (must be x64 or arm64)"
        exit 1
        ;;
esac

# ----- Color helpers -----
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[1;36m'
NC='\033[0m'

log()         { echo -e "${CYAN}==>${NC} $*"; }
log_success() { echo -e "${GREEN}==>${NC} $*"; }
log_error()   { echo -e "${RED}==>${NC} $*" >&2; }

# ----- Ensure dotnet is on PATH -----
export PATH="$scriptroot/.dotnet:$PATH"

# ----- Determine configs to compare -----
configs=()
case "$config" in
    debug)   configs=(debug) ;;
    release) configs=(release) ;;
    both)    configs=(debug release) ;;
    *)
        echo "Invalid config: $config (must be debug, release, or both)"
        exit 1
        ;;
esac

# ----- Determine Bazel platform flags -----
bazel_platform_args=()
if [[ "$arch" == "arm64" ]]; then
    bazel_platform_args=(--platforms=//platforms:linux_arm64)
fi

overall_exit=0
bazel_scope_targets=(
    //src/coreclr/...
    //src/libraries/...
    //src/native/...
    //src/tools/illink/...
)
bazel_scope_query='//src/coreclr/... union //src/libraries/... union //src/native/... union //src/tools/illink/...'

for cfg in "${configs[@]}"; do
    log "════════════════════════════════════════════════════"
    log "  Configuration: $cfg / $arch"
    log "════════════════════════════════════════════════════"

    # ----- Map config to build system flags -----
    # Always include --ci for MSBuild and --config=ci for Bazel so the
    # comparison reflects CI-mode deterministic source paths.
    if [[ "$cfg" == "debug" ]]; then
        msbuild_rc="Debug"
        bazel_aquery_args=(--config=clr_debug --config=ci "${bazel_platform_args[@]}")
    else
        msbuild_rc="Release"
        bazel_aquery_args=(--config=release --config=ci "${bazel_platform_args[@]}")
    fi

    # ----- CMake compile_commands.json paths -----
    # Paths follow the CMake output directory convention:
    #   coreclr:    artifacts/obj/coreclr/linux.{arch}.{Config}/
    #   corehost:   artifacts/obj/linux-{arch}.{Config}/
    #   native libs: artifacts/obj/native/net10.0-linux-{Config}-{arch}/
    cmake_coreclr_cc="$scriptroot/artifacts/obj/coreclr/linux.${arch}.${msbuild_rc}/compile_commands.json"
    cmake_corehost_cc="$scriptroot/artifacts/obj/linux-${arch}.${msbuild_rc}/compile_commands.json"
    cmake_nativelibs_cc="$scriptroot/artifacts/obj/native/net10.0-linux-${msbuild_rc}-${arch}/compile_commands.json"

    # ----- MSBuild binlog path -----
    binlog_dir="$scriptroot/artifacts/log/${msbuild_rc}"

    # ----- Bazel aquery output paths -----
    aquery_dir="$scriptroot/artifacts/obj/bazel-aquery"
    mkdir -p "$aquery_dir"
    bazel_native_aquery="$aquery_dir/${cfg}-${arch}-native.json"
    bazel_managed_aquery="$aquery_dir/${cfg}-${arch}-managed.json"

    # ----- Step 1: Build with CMake/MSBuild -----
    if [[ -z "$msbuild_json" && "$skip_build" != "true" ]]; then
        # Use a rebuild so the binlog contains the full managed compilation set.
        # An incremental build only records the Csc tasks that reran, which makes
        # the managed equivalence check compare a tiny overlap set.
        msbuild_arch_args=()
        if [[ "$arch" != "x64" ]]; then
            msbuild_arch_args=(-arch "$arch" /p:CrossBuild=true)
        fi
        log "Building with CMake/MSBuild (./build.sh clr+libs+libs.tests --rebuild --ci -c $cfg -rc $cfg -lc $cfg ${msbuild_arch_args[*]} -bl)..."
        "$scriptroot/build.sh" clr+libs+libs.tests --rebuild --ci -c "$cfg" -rc "$cfg" -lc "$cfg" "${msbuild_arch_args[@]}" -bl
    fi

    # ----- Step 2: Build with Bazel + extract aquery -----
    # Build first so that generated source files (AssemblyInfo.cs, System.SR.cs)
    # are materialized on disk with the correct CI-mode content.  The aquery
    # alone only performs analysis and does not write generated files.
    #
    # Keep the Bazel scope aligned with MSBuild's clr+libs+libs.tests subset.
    # Querying //... pulls in unrelated targets (for example src/tests/JIT and
    # other helper graphs) that the MSBuild subset never builds, which floods
    # the managed comparison with only-in-Bazel noise.
    if [[ "$skip_build" != "true" ]]; then
        log "Building with Bazel (bazel build ${bazel_aquery_args[*]} ${bazel_scope_targets[*]})..."
        bazel --nohome_rc build "${bazel_aquery_args[@]}" "${bazel_scope_targets[@]}"
    fi

    # Extract aquery unless pre-generated files already exist.
    # For cross-compilation targets (e.g. arm64), the aquery must be run inside
    # the cross-build container where the toolchain is available.  Pre-generate
    # the aquery files and pass --skip-build to use them.
    if [[ ! -s "$bazel_native_aquery" ]]; then
        log "Extracting Bazel aquery (native)..."
        bazel --nohome_rc aquery \
            "${bazel_aquery_args[@]}" \
            --output=jsonproto \
            "mnemonic(\"CppCompile\", ${bazel_scope_query})" \
            > "$bazel_native_aquery" 2>/dev/null
    else
        log "Using existing Bazel aquery (native): $bazel_native_aquery"
    fi

    if [[ ! -s "$bazel_managed_aquery" ]]; then
        log "Extracting Bazel aquery (managed)..."
        bazel --nohome_rc aquery \
            "${bazel_aquery_args[@]}" \
            --output=jsonproto \
            "mnemonic(\"CSharpCompile\", ${bazel_scope_query})" \
            > "$bazel_managed_aquery" 2>/dev/null
    else
        log "Using existing Bazel aquery (managed): $bazel_managed_aquery"
    fi

    # ----- Step 3: Find binlog files -----
    binlog_args=()
    if [[ -z "$msbuild_json" && -d "$binlog_dir" ]]; then
        while IFS= read -r -d '' f; do
            binlog_args+=(--binlog "$f")
        done < <(find "$binlog_dir" -name "*.binlog" -print0)
    fi

    # ----- Step 4: Build the analysis tool -----
    log "Building analysis tool..."
    "$scriptroot/dotnet.sh" build "$scriptroot/src/tools/bazel/BuildEquivalenceCheck/BuildEquivalenceCheck.csproj" \
        --nologo -v quiet 2>&1

    # ----- Step 5: Run comparison -----
    log "Running equivalence check..."

    # Use arch-specific manifest if it exists, otherwise fall back to the
    # shared manifest.  This allows platform-specific overrides (e.g. for
    # assemblies that only exist on one architecture) while keeping the
    # common case simple.
    manifest_dir="$scriptroot/src/tools/bazel/BuildEquivalenceCheck"
    if [[ -f "$manifest_dir/managed-assembly-manifest.linux-${arch}.txt" ]]; then
        managed_manifest="$manifest_dir/managed-assembly-manifest.linux-${arch}.txt"
    else
        managed_manifest="$manifest_dir/managed-assembly-manifest.txt"
    fi

    tool_args=(
        --repo-root "$scriptroot"
        --bazel-native-aquery "$bazel_native_aquery"
        --bazel-managed-aquery "$bazel_managed_aquery"
        --managed-manifest "$managed_manifest"
    )

    # Add compile_commands.json files that exist
    for cc in "$cmake_coreclr_cc" "$cmake_corehost_cc" "$cmake_nativelibs_cc"; do
        if [[ -f "$cc" ]]; then
            tool_args+=(--cmake-compile-commands "$cc")
        else
            log "  (skipping missing compile_commands: $cc)"
        fi
    done

    # Use pre-extracted MSBuild JSON if provided, otherwise use binlog files
    if [[ -n "$msbuild_json" ]]; then
        tool_args+=(--msbuild-json "$msbuild_json")
    else
        tool_args+=("${binlog_args[@]}")
    fi

    if [[ "$verbose" == "true" ]]; then
        tool_args+=(--verbose)
    fi

    if [[ -n "$json_output" ]]; then
        local_json="${json_output%.json}-${cfg}.json"
        tool_args+=(--json-output "$local_json")
    fi

    "$scriptroot/dotnet.sh" run --project "$scriptroot/src/tools/bazel/BuildEquivalenceCheck/BuildEquivalenceCheck.csproj" \
        --no-build -- "${tool_args[@]}" || overall_exit=1

    echo ""
done

if [[ "$overall_exit" -eq 0 ]]; then
    log_success "All equivalence checks passed."
else
    log_error "Some equivalence checks found differences."
fi

exit "$overall_exit"
