// Root BuildXL configuration for the runtime repo test build.
//
// External rule SDKs are fetched via GitRepository/Download so the workspace
// can build against the latest pinned BuildXL rule snapshots without relying
// on sibling checkouts.
//
// For local development with modified rules, temporarily replace the
// GitRepository block with a DScript block pointing at local checkouts and
// add corresponding mounts. See README or checkpoints for details.
config({
    resolvers: [
        {
            kind: "DScript",
            modules: [
                f`${Environment.getPathValue("BUILDXL_BIN")}/Sdk/Sdk.Prelude/package.config.dsc`,
                f`${Environment.getPathValue("BUILDXL_BIN")}/Sdk/Sdk.Transformers/package.config.dsc`,
            ]
        },
        {
            kind: "GitRepository",
            repositories: [
                {
                    moduleName: "bxl_rules_repo",
                    owner: "agocke",
                    repository: "bxl_rules",
                    commit: "684f3255dcbd4ca08acede8eda932347bb6f9578",
                },
                {
                    moduleName: "bxl_rules_dotnet_repo",
                    owner: "agocke",
                    repository: "bxl_rules_dotnet",
                    commit: "c1434b76c42f427f3431cba270096a600b263844",
                },
            ],
        },
        {
            kind: "DScript",
            modules: [
                // Repo-specific definitions
                f`defs/module.config.dsc`,

                // Common test support libraries
                f`src/tests/Common/module.config.dsc`,

                // Repo-specific test macro (like src/tests/live_test.bzl)
                f`src/tests/coreclr_test/module.config.dsc`,

                // Test modules
                f`src/tests/baseservices/TieredCompilation/module.config.dsc`
            ]
        },
        {
            kind: "Download",
            downloads: [
                {
                    moduleName: "DotNetSdk",
                    url: "https://ci.dot.net/public/Sdk/11.0.100-preview.5.26227.104/dotnet-sdk-11.0.100-preview.5.26227.104-linux-x64.tar.gz",
                    archiveType: "tgz",
                },
                {
                    moduleName: "Microsoft.DotNet.XUnitAssert",
                    url: "https://pkgs.dev.azure.com/dnceng/public/_packaging/dotnet-eng/nuget/v3/flat2/microsoft.dotnet.xunitassert/3.2.2-beta.26211.102/microsoft.dotnet.xunitassert.3.2.2-beta.26211.102.nupkg",
                    archiveType: "zip",
                },
                {
                    moduleName: "xunit.extensibility.core",
                    url: "https://api.nuget.org/v3-flatcontainer/xunit.extensibility.core/2.9.3/xunit.extensibility.core.2.9.3.nupkg",
                    archiveType: "zip",
                },
                {
                    moduleName: "Microsoft.DotNet.XUnitExtensions",
                    url: "https://pkgs.dev.azure.com/dnceng/public/_packaging/dotnet-eng/nuget/v3/flat2/microsoft.dotnet.xunitextensions/11.0.0-beta.26211.102/microsoft.dotnet.xunitextensions.11.0.0-beta.26211.102.nupkg",
                    archiveType: "zip",
                },
                {
                    moduleName: "xunit.abstractions",
                    url: "https://api.nuget.org/v3-flatcontainer/xunit.abstractions/2.0.3/xunit.abstractions.2.0.3.nupkg",
                    archiveType: "zip",
                },
            ],
        },
    ],

    mounts: [
        {
            name: a`SourceRoot`,
            path: p`.`,
            trackSourceFileChanges: true,
            isReadable: true
        },
        {
            name: a`BuildXLSdk`,
            path: p`${Environment.getPathValue("BUILDXL_BIN")}/Sdk`,
            trackSourceFileChanges: true,
            isReadable: true
        }
    ]
});
