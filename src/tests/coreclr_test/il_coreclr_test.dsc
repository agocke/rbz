// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

/**
 * il_coreclr_test — repo-specific build macro for CoreCLR IL tests.
 *
 * Assembles one or more .il source files into a test assembly using the
 * pre-built native ilasm from Core_Root, then wires the same
 * BuildXL-backed execution pip used by `coreclr_test` to run the
 * resulting binary via corerun.
 */

import * as Rules from "Sdk.Rules";
import {Cmd, Transformer} from "Sdk.Transformers";
import * as Defs from "Defs";

// ============================================================================
//  Internal ilasm-compile rule
// ============================================================================

interface IlCompileAttrs {
    name: string;
    srcs: Rules.Label[];
    debugType?: string;
    optimize?: boolean;
}

interface IlCompileResolved {
    name: string;
    srcs: Rules.Artifact[];
    debugType?: string;
    optimize?: boolean;
}

interface IlCompileResult extends Rules.Provider {
    binary: File;
    defaultInfo: Rules.DefaultInfo;
}

const ilCompile = Rules.rule<IlCompileAttrs, IlCompileResolved, Rules.Toolchain, IlCompileResult>({
    doc: "Assemble .il source files into a .dll using ilasm.",
    toolchain: supportToolchain,
    resolve: (attrs, resolver) => <IlCompileResolved>{
        name: attrs.name,
        srcs: resolver.resolveAll(attrs.srcs),
        debugType: attrs.debugType,
        optimize: attrs.optimize,
    },
    impl: (ctx) => {
        const dll = ctx.actions.declareOutput(`${ctx.args.name}.dll`);

        let cmdArgs: Argument[] = [Cmd.argument("-quiet"), Cmd.argument("-dll")];
        if (ctx.args.debugType === "full") {
            cmdArgs = cmdArgs.push(Cmd.argument("-debug"));
        } else if (ctx.args.debugType === "pdbonly") {
            cmdArgs = cmdArgs.push(Cmd.argument("-debug=opt"));
        }
        if (ctx.args.optimize === true) {
            cmdArgs = cmdArgs.push(Cmd.argument("-optimize"));
        }
        cmdArgs = cmdArgs.push(Cmd.option("-output=", Rules.cmdOutput(dll)));
        for (const s of ctx.args.srcs) {
            cmdArgs = cmdArgs.push(Cmd.argument(Rules.cmdInput(s)));
        }

        const produced = ctx.actions.run({
            tool: Rules.sourceArtifact(Defs.CORE_ROOT_ILASM),
            arguments: cmdArgs,
            outputs: [dll],
            description: `ilasm ${ctx.args.name}`,
        });

        const binaryFile = Rules.getFile(produced[0]);
        return {
            kind: "IlCompileResult",
            binary: binaryFile,
            defaultInfo: Rules.defaultInfo({ files: [binaryFile] }),
        };
    },
});

// ============================================================================
//  il_coreclr_test public API
// ============================================================================

@@public
export interface IlCoreClrTestArguments {
    name: string;
    srcs: Rules.Label[];
    debugType?: string;
    optimize?: boolean;
    env?: {name: string, value: string}[];
    run?: boolean;
    // ------------------------------------------------------------------
    // Bazel-compat attributes, accepted for 1:1 pass-through from the
    // port script. Most are no-ops at this layer.
    // ------------------------------------------------------------------
    pri?: number;
    size?: string;
    tags?: string[];
    flaky?: boolean;
    visibility?: string[];
    targetCompatibleWith?: string[];
}

@@public
export interface IlCoreClrTestResult extends Rules.Provider {
    binary: File;
    buildStamp: File;
    testStamp?: File;
    defaultInfo: Rules.DefaultInfo;
}

@@public
export function il_coreclr_test(args: IlCoreClrTestArguments): IlCoreClrTestResult {
    const ilResult = ilCompile({
        name: args.name,
        srcs: args.srcs,
        debugType: args.debugType,
        optimize: args.optimize,
    });

    const buildStamp = emitBuildStamp({
        name: `${args.name}_build`,
        binary: ilResult.binary,
    }).stamp;

    // Tests carrying the bazel "manual" tag are compiled but not run by default.
    const taggedManual = (args.tags || []).filter(t => t === "manual").length > 0;
    const shouldRun = args.run !== false && !taggedManual;
    const testStamp = !shouldRun
        ? undefined
        : runCoreClrTest({
            name: `${args.name}_test`,
            binary: ilResult.binary,
            runtimeFiles: [],
            environmentVariables: args.env || [],
        }).stamp;

    return {
        kind: "IlCoreClrTestResult",
        binary: ilResult.binary,
        buildStamp: buildStamp,
        testStamp: testStamp,
        defaultInfo: Rules.defaultInfo({
            files: testStamp !== undefined ? [buildStamp, testStamp] : [buildStamp],
        }),
    };
}
