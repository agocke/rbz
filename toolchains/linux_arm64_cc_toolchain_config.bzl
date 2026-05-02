"""CC toolchain config for cross-compiling to linux-arm64 (aarch64-linux-gnu).

Uses the system Clang compiler with --target=aarch64-linux-gnu for cross-compilation.
Clang is inherently a cross-compiler and already supports -ferror-limit and other
Clang-specific flags used in .bazelrc.
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

_SYSROOT = "/usr/aarch64-linux-gnu"

def _impl(ctx):
    tool_paths = [
        tool_path(name = "gcc", path = "/usr/bin/clang"),
        tool_path(name = "g++", path = "/usr/bin/clang++"),
        tool_path(name = "ld", path = "/usr/bin/aarch64-linux-gnu-ld"),
        tool_path(name = "ar", path = "/usr/bin/aarch64-linux-gnu-ar"),
        tool_path(name = "cpp", path = "/usr/bin/clang-cpp"),
        tool_path(name = "gcov", path = "/usr/bin/llvm-cov"),
        tool_path(name = "nm", path = "/usr/bin/aarch64-linux-gnu-nm"),
        tool_path(name = "objdump", path = "/usr/bin/aarch64-linux-gnu-objdump"),
        tool_path(name = "strip", path = "/usr/bin/aarch64-linux-gnu-strip"),
        tool_path(name = "objcopy", path = "/usr/bin/aarch64-linux-gnu-objcopy"),
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
                            "--sysroot=" + _SYSROOT,
                            # Add system include paths for multiarch dev packages
                            # (libssl-dev:arm64, libkrb5-dev:arm64 install to /usr/include)
                            "-isystem", "/usr/include/aarch64-linux-gnu",
                            "-isystem", "/usr/include",
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
                            # Don't pass --sysroot for linking: the GNU linker scripts
                            # in the cross-sysroot contain absolute paths that lld would
                            # try to resolve relative to the sysroot, causing double-prefix.
                            # Instead, use -L to point at the cross-sysroot lib directly.
                            "-L" + _SYSROOT + "/lib",
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
            "/usr/aarch64-linux-gnu/include",
            "/usr/include/aarch64-linux-gnu",
            "/usr/include",
            "/usr/lib/llvm-18/lib/clang/18/include",
            "/usr/lib/clang/18/include",
        ],
    )

linux_arm64_cc_toolchain_config = rule(
    implementation = _impl,
    attrs = {},
    provides = [CcToolchainConfigInfo],
)
