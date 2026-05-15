// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

import * as CSharp from "Sdk.Rules.CSharp";
import * as Defs from "Defs";
import {Cmd} from "Sdk.Transformers";

const dotnetSdk = importFrom("DotNetSdk").extracted;
const sdkVersion = "11.0.100-preview.5.26227.104";

function sdkFile(path: string): File {
    return dotnetSdk.assertExistence(r`sdk/${sdkVersion}/${path}`);
}

// The Download resolver drops file-level symlinks from the SDK tarball.
// Roslyn/bincore/csc.dll expects Microsoft.CodeAnalysis.dll next to it (via
// symlink), but the real file is at the SDK root.  Tell the dotnet host to
// also probe the SDK root directory so csc can find its dependencies.
const sdkRootPath = sdkFile("Microsoft.CodeAnalysis.dll").parent;

@@public
export const csharpToolchain = CSharp.csharpToolchainFromContents({
    name: "dotnet-sdk",
    contents: dotnetSdk,
    compilerPath: `sdk/${sdkVersion}/Roslyn/bincore/csc.dll`,
    hostArguments: [
        Cmd.option("--additionalprobingpath ", sdkRootPath),
    ],
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
        ...Defs.XUNIT_DEPS,
        "@Microsoft.NETCore.App.Ref//ref/net11.0:System.Text.Json.dll",
    ],
    externalPackages: Defs.EXTERNAL_PACKAGES,
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

@@public
export const xunitWrapperLibrary = CSharp.csharp_library({
    name: "XUnitWrapperLibrary",
    toolchain: csharpToolchain,
    srcs: [
        "XUnitWrapperLibrary/Help.cs",
        "XUnitWrapperLibrary/TestFilter.cs",
        "XUnitWrapperLibrary/TestOutputRecorder.cs",
        "XUnitWrapperLibrary/TestSummary.cs",
    ],
    refs: [
        ...Defs.CORE_ROOT_REFPACK_DEPS,
        "@Microsoft.NETCore.App.Ref//ref/net11.0:System.Xml.ReaderWriter.dll",
    ],
    externalPackages: Defs.EXTERNAL_PACKAGES,
    allowUnsafe: true,
});

@@public
export const xunitWrapperGenerator = CSharp.csharp_library({
    name: "XUnitWrapperGenerator",
    toolchain: csharpToolchain,
    srcs: [
        "XUnitWrapperGenerator/CodeBuilder.cs",
        "XUnitWrapperGenerator/Descriptors.cs",
        "XUnitWrapperGenerator/ImmutableDictionaryValueComparer.cs",
        "XUnitWrapperGenerator/ITestInfo.cs",
        "XUnitWrapperGenerator/OptionsHelper.cs",
        "XUnitWrapperGenerator/RoslynUtils.cs",
        "XUnitWrapperGenerator/RuntimeConfiguration.cs",
        "XUnitWrapperGenerator/RuntimeTestModes.cs",
        "XUnitWrapperGenerator/SymbolExtensions.cs",
        "XUnitWrapperGenerator/TargetFrameworkMonikers.cs",
        "XUnitWrapperGenerator/TestPlatforms.cs",
        "XUnitWrapperGenerator/TestRuntimes.cs",
        "XUnitWrapperGenerator/XUnitWrapperGenerator.cs",
        "XUnitWrapperLibrary/TestFilter.cs",
    ],
    refs: Defs.CORE_ROOT_REFPACK_DEPS,
    externalPackages: Defs.EXTERNAL_PACKAGES,
    fileRefs: [
        sdkFile("Microsoft.CodeAnalysis.dll"),
        sdkFile("Microsoft.CodeAnalysis.CSharp.dll"),
    ],
});
