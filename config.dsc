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
                f`${Environment.getPathValue("BUILDXL_BIN")}/Sdk/Sdk.Managed.Shared/module.config.dsc`,
            ]
        },
        {
            kind: "GitRepository",
            repositories: [
                {
                    moduleName: "bxl_rules_repo",
                    owner: "agocke",
                    repository: "bxl_rules",
                    commit: "3a494442b296c7459a4efdcfdccda5d66b6fe41a",
                },
                {
                    moduleName: "bxl_rules_dotnet_repo",
                    owner: "agocke",
                    repository: "bxl_rules_dotnet",
                    commit: "52b26eaba24e173b5877c24ecc63c059f6bb77a5",
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
            ],
        },
        {
            kind: "Nuget",
            repositories: {
                "nuget.org": "https://api.nuget.org/v3/index.json",
                "dotnet-eng": "https://pkgs.dev.azure.com/dnceng/public/_packaging/dotnet-eng/nuget/v3/index.json",
            },
            packages: [
                { id: "Microsoft.DotNet.XUnitAssert", version: "3.2.2-beta.26211.102", alias: "Microsoft.DotNet.XUnitAssert" },
                { id: "xunit.extensibility.core", version: "2.9.3", dependentPackageIdsToIgnore: ["NETStandard.Library"] },
                { id: "Microsoft.DotNet.XUnitExtensions", version: "11.0.0-beta.26211.102", alias: "Microsoft.DotNet.XUnitExtensions", dependentPackageIdsToIgnore: ["NETStandard.Library", "System.Runtime.InteropServices.RuntimeInformation"] },
                { id: "xunit.abstractions", version: "2.0.3", dependentPackageIdsToIgnore: ["NETStandard.Library"] },
                { id: "xunit.extensibility.execution", version: "2.9.3", dependentPackageIdsToIgnore: ["NETStandard.Library"] },
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
