# Repository rule to find ICU4C headers on macOS (Homebrew) or Linux (system).

def _icu4c_repository_impl(rctx):
    # Detect the OS
    os_name = rctx.os.name.lower()

    if "mac" in os_name or "darwin" in os_name:
        # macOS: use Homebrew ICU4C
        # Check both arm64 and x64 Homebrew paths
        arm64_path = "/opt/homebrew/opt/icu4c"
        x64_path = "/usr/local/opt/icu4c"

        if rctx.path(arm64_path).exists:
            icu_path = arm64_path
        elif rctx.path(x64_path).exists:
            icu_path = x64_path
        else:
            fail("ICU4C not found. Install with: brew install icu4c")

        # Symlink the include directory
        rctx.symlink(icu_path + "/include", "include")
    else:
        # Linux: check DOTNET_ICU_INCLUDE env var first, then fall back to
        # /usr/include/unicode (standard system-wide location).
        custom_path = rctx.os.environ.get("DOTNET_ICU_INCLUDE", "")
        if custom_path:
            icu_unicode_dir = custom_path
        else:
            icu_unicode_dir = "/usr/include/unicode"
        rctx.symlink(icu_unicode_dir, "include/unicode")

    # Write the BUILD file
    rctx.file("BUILD.bazel", """
load("@rules_cc//cc:defs.bzl", "cc_library")

cc_library(
    name = "headers",
    hdrs = glob(["include/unicode/*.h"]),
    includes = ["include"],
    visibility = ["//visibility:public"],
)
""")

icu4c_repository = repository_rule(
    implementation = _icu4c_repository_impl,
    local = True,
    environ = ["DOTNET_ICU_INCLUDE"],
    doc = "Locates ICU4C headers on macOS (Homebrew) or Linux (system). " +
          "Set DOTNET_ICU_INCLUDE to override the Linux include path " +
          "(e.g. /crossrootfs/arm64/usr/include/unicode).",
)
