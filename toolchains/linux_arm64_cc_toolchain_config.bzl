"""CC toolchain config for cross-compiling to linux-arm64 (aarch64-linux-gnu).

Uses the system Clang compiler with --target=aarch64-linux-gnu for cross-compilation.
Clang is inherently a cross-compiler and already supports -ferror-limit and other
Clang-specific flags used in .bazelrc.

The sysroot and tool paths are configured via attributes so the same rule works
in different environments (bare host with multiarch packages, or the dotnet
cross-build container with rootfs at /crossrootfs/arm64).
"""

load("@rules_cc//cc:cc_toolchain_config_lib.bzl",
     "feature",
     "flag_group",
     "flag_set",
     "tool_path",
     "with_feature_set",
)
load("@rules_cc//cc:action_names.bzl", "ACTION_NAMES")
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("@rules_cc//cc/toolchains:cc_toolchain_config_info.bzl", "CcToolchainConfigInfo")

_ALL_COMPILE_ACTIONS = [
    ACTION_NAMES.c_compile,
    ACTION_NAMES.cpp_compile,
    ACTION_NAMES.cpp_header_parsing,
    ACTION_NAMES.cpp_module_compile,
    ACTION_NAMES.cpp_module_codegen,
    ACTION_NAMES.assemble,
    ACTION_NAMES.preprocess_assemble,
]

_ALL_LINK_ACTIONS = [
    ACTION_NAMES.cpp_link_executable,
    ACTION_NAMES.cpp_link_dynamic_library,
    ACTION_NAMES.cpp_link_nodeps_dynamic_library,
]

def _impl(ctx):
    sysroot = ctx.attr.sysroot
    clang_prefix = ctx.attr.clang_prefix

    tool_paths = [
        tool_path(name = "gcc", path = clang_prefix + "/clang"),
        tool_path(name = "g++", path = clang_prefix + "/clang++"),
        tool_path(name = "ld", path = clang_prefix + "/ld.lld"),
        tool_path(name = "ar", path = clang_prefix + "/llvm-ar"),
        tool_path(name = "cpp", path = clang_prefix + "/clang-cpp"),
        tool_path(name = "gcov", path = clang_prefix + "/llvm-cov"),
        tool_path(name = "nm", path = clang_prefix + "/llvm-nm"),
        tool_path(name = "objdump", path = clang_prefix + "/llvm-objdump"),
        tool_path(name = "strip", path = clang_prefix + "/llvm-strip"),
        tool_path(name = "objcopy", path = clang_prefix + "/llvm-objcopy"),
    ]

    default_compile_flags = feature(
        name = "default_compile_flags",
        enabled = True,
        flag_sets = [
            flag_set(
                actions = _ALL_COMPILE_ACTIONS,
                flag_groups = [
                    flag_group(
                        flags = [
                            "--target=aarch64-linux-gnu",
                            "--sysroot=" + sysroot,
                            "-no-canonical-prefixes",
                            "-Wno-builtin-macro-redefined",
                            "-D__DATE__=\"redacted\"",
                            "-D__TIMESTAMP__=\"redacted\"",
                            "-D__TIME__=\"redacted\"",
                        ],
                    ),
                ],
            ),
        ],
    )

    default_link_flags = feature(
        name = "default_link_flags",
        enabled = True,
        flag_sets = [
            flag_set(
                actions = _ALL_LINK_ACTIONS,
                flag_groups = [
                    flag_group(
                        flags = [
                            "--target=aarch64-linux-gnu",
                            "-fuse-ld=lld",
                            "--sysroot=" + sysroot,
                            "-lstdc++",
                            "-lm",
                        ],
                    ),
                ],
            ),
        ],
    )

    supports_dynamic_linker = feature(
        name = "supports_dynamic_linker",
        enabled = True,
    )

    supports_pic = feature(
        name = "supports_pic",
        enabled = True,
    )

    pic_feature = feature(
        name = "pic",
        enabled = True,
        flag_sets = [
            flag_set(
                actions = _ALL_COMPILE_ACTIONS,
                flag_groups = [
                    flag_group(flags = ["-fPIC"]),
                ],
                with_features = [with_feature_set(features = ["pic"])],
            ),
        ],
    )

    dbg_feature = feature(
        name = "dbg",
        flag_sets = [
            flag_set(
                actions = _ALL_COMPILE_ACTIONS,
                flag_groups = [flag_group(flags = ["-g"])],
            ),
        ],
    )

    opt_feature = feature(
        name = "opt",
        flag_sets = [
            flag_set(
                actions = _ALL_COMPILE_ACTIONS,
                flag_groups = [flag_group(flags = ["-O2", "-DNDEBUG"])],
            ),
        ],
    )

    features = [
        default_compile_flags,
        default_link_flags,
        supports_dynamic_linker,
        supports_pic,
        pic_feature,
        dbg_feature,
        opt_feature,
    ]

    # Clang's own resource headers (stddef.h, stdarg.h, etc.)
    clang_builtin_dirs = [d for d in ctx.attr.clang_resource_dirs if d]

    return cc_common.create_cc_toolchain_config_info(
        ctx = ctx,
        features = features,
        toolchain_identifier = "clang-aarch64-linux-gnu",
        host_system_name = "x86_64-linux-gnu",
        target_system_name = "aarch64-linux-gnu",
        target_cpu = "aarch64",
        target_libc = "glibc",
        compiler = "clang",
        abi_version = "clang",
        abi_libc_version = "glibc",
        tool_paths = tool_paths,
        cxx_builtin_include_directories = [
            sysroot + "/usr/include/aarch64-linux-gnu",
            sysroot + "/usr/include",
            sysroot + "/include",
        ] + clang_builtin_dirs,
    )

linux_arm64_cc_toolchain_config = rule(
    implementation = _impl,
    attrs = {
        "sysroot": attr.string(
            default = "/crossrootfs/arm64",
            doc = "Path to the arm64 sysroot (rootfs). Default is the dotnet cross-build container path.",
        ),
        "clang_prefix": attr.string(
            default = "/usr/local/bin",
            doc = "Directory containing clang, ld.lld, llvm-ar, etc.",
        ),
        "clang_resource_dirs": attr.string_list(
            default = [],
            doc = "Clang resource/builtin header directories (e.g. /usr/local/lib/clang/22/include).",
        ),
    },
    provides = [CcToolchainConfigInfo],
)
