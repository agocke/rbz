// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

import * as CSharp from "Sdk.Rules.CSharp";
import * as Defs from "Defs";

const dotNetRoot = Environment.getPathValue("DOTNET_ROOT");
const dotNetSdkVersion = Environment.getStringValue("DOTNET_SDK_VERSION");

const csharpToolchain = CSharp.csharpToolchain({
    name: "dotnet-sdk",
    hostExe: f`${dotNetRoot}/dotnet`,
    compiler: f`${dotNetRoot}/sdk/${dotNetSdkVersion}/Roslyn/bincore/csc.dll`,
});

@@public
export const testLibrary = CSharp.csharp_library({
    name: "TestLibrary",
    toolchain: csharpToolchain,
    srcs: [
        "CoreCLRTestLibrary/AssertExtensions.cs",
        "CoreCLRTestLibrary/CoreclrTestWrapperLib.cs",
        "CoreCLRTestLibrary/CoreClrConfigurationDetection.cs",
        "CoreCLRTestLibrary/Generator.cs",
        "CoreCLRTestLibrary/HostPolicyMock.cs",
        "CoreCLRTestLibrary/Logging.cs",
        "CoreCLRTestLibrary/PlatformDetection.cs",
        "CoreCLRTestLibrary/TestFramework.cs",
        "CoreCLRTestLibrary/Utilities.cs",
        "CoreCLRTestLibrary/Vectors.cs",
        "CoreCLRTestLibrary/XPlatformUtils.cs",
    ],
    refs: [
        ...Defs.CORE_ROOT_REFPACK_DEPS,
        "//artifacts/bin/System.Text.Json/ref/Release/net11.0:System.Text.Json.dll",
    ],
    fileRefs: Defs.XUNIT_DEPS,
    allowUnsafe: true,
    nowarn: [
        "CS0419",
        "CS1572",
        "CS1574",
        "CS1710",
        "CS3001",
        "CS3002",
        "CS3003",
    ],
});
