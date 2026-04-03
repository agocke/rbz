// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.

using System.Text;
using Microsoft.Build.Logging.StructuredLogger;
using MSBuildTask = Microsoft.Build.Logging.StructuredLogger.Task;

namespace BuildEquivalenceCheck;

/// <summary>
/// Parses MSBuild binary log (.binlog) files to extract Csc task invocations
/// by reading the full compiler command line from each Csc task.
/// </summary>
public static class BinlogParser
{
    public static List<ManagedCompilationRecord> Parse(string binlogPath, string repoRoot)
    {
        var records = new List<ManagedCompilationRecord>();
        var build = BinaryLog.ReadBuild(binlogPath);

        build.VisitAllChildren<MSBuildTask>(task =>
        {
            if (!string.Equals(task.Name, "Csc", StringComparison.OrdinalIgnoreCase))
                return;

            var record = ExtractFromCscTask(task, repoRoot);
            if (record is not null)
                records.Add(record);
        });

        return records;
    }

    private static ManagedCompilationRecord? ExtractFromCscTask(MSBuildTask task, string repoRoot)
    {
        var commandLine = task.CommandLineArguments;
        if (string.IsNullOrWhiteSpace(commandLine))
            return null;

        // Resolve relative source paths against the project directory, not CWD.
        var projectDirectory = task.GetNearestParent<Project>()?.ProjectDirectory ?? repoRoot;

        var args = SplitCommandLine(commandLine);
        return ParseCscArguments(args, projectDirectory, repoRoot);
    }

    /// <summary>
    /// Parse a list of csc command-line arguments into a <see cref="ManagedCompilationRecord"/>.
    /// The argument list should already have the tool path stripped or it will be
    /// skipped automatically (first token ending in .dll or .exe).
    /// </summary>
    private static ManagedCompilationRecord? ParseCscArguments(
        List<string> args, string projectDirectory, string repoRoot)
    {
        var sourceFiles = new SortedSet<string>(StringComparer.Ordinal);
        var sourceFileOriginalPaths = new Dictionary<string, string>(StringComparer.Ordinal);
        var defines = new SortedSet<string>(StringComparer.Ordinal);
        var references = new SortedSet<string>(StringComparer.Ordinal);
        var referencePaths = new Dictionary<string, string>(StringComparer.Ordinal);
        var analyzers = new SortedSet<string>(StringComparer.Ordinal);
        var flags = new SortedSet<string>(StringComparer.Ordinal);
        string targetType = "library";
        string langVersion = "";
        string? assemblyName = null;
        string? outputPath = null;
        bool firstArg = true;

        foreach (var arg in args)
        {
            // Skip the tool path (first argument, e.g. /path/to/csc.dll)
            if (firstArg)
            {
                firstArg = false;
                if (arg.EndsWith(".dll", StringComparison.OrdinalIgnoreCase)
                    || arg.EndsWith(".exe", StringComparison.OrdinalIgnoreCase))
                    continue;
            }

            if (arg.StartsWith("/define:") || arg.StartsWith("/d:") || arg.StartsWith("-define:") || arg.StartsWith("-d:"))
            {
                var value = arg[(arg.IndexOf(':') + 1)..];
                foreach (var d in value.Split(';', StringSplitOptions.RemoveEmptyEntries))
                    defines.Add(d.Trim());
            }
            else if (arg.StartsWith("/nowarn:") || arg.StartsWith("-nowarn:"))
            {
                // Expand comma-separated codes into individual /nowarn: flags.
                foreach (var w in arg[(arg.IndexOf(':') + 1)..].Split(',', StringSplitOptions.RemoveEmptyEntries))
                    flags.Add("/nowarn:" + NormalizeWarningCode(w.Trim()));
            }
            else if (arg.StartsWith("/r:") || arg.StartsWith("-r:")
                || arg.StartsWith("/reference:") || arg.StartsWith("-reference:"))
            {
                var refPath = arg[(arg.IndexOf(':') + 1)..];
                var name = Path.GetFileNameWithoutExtension(refPath);
                references.Add(name);
                var fullPath = Path.IsPathRooted(refPath)
                    ? Path.GetFullPath(refPath)
                    : Path.GetFullPath(Path.Combine(projectDirectory, refPath));
                referencePaths.TryAdd(name, fullPath);
            }
            else if (arg.StartsWith("/analyzer:") || arg.StartsWith("-analyzer:"))
            {
                analyzers.Add(Path.GetFileNameWithoutExtension(arg[(arg.IndexOf(':') + 1)..]));
            }
            else if (arg.StartsWith("/target:") || arg.StartsWith("-target:"))
            {
                targetType = arg[(arg.IndexOf(':') + 1)..];
            }
            else if (arg.StartsWith("/langversion:") || arg.StartsWith("-langversion:"))
            {
                langVersion = arg[(arg.IndexOf(':') + 1)..];
            }
            else if (arg.StartsWith("/out:") || arg.StartsWith("-out:"))
            {
                var outPath = arg[(arg.IndexOf(':') + 1)..];
                assemblyName = Path.GetFileNameWithoutExtension(outPath);
                outputPath = outPath;
            }
            else if (arg.StartsWith('/') || arg.StartsWith('-'))
            {
                // Other csc flags — skip the response file marker (@file)
                flags.Add(arg);
            }
            else if (arg.StartsWith('@'))
            {
                // Response file reference — skip
            }
            else if (arg.EndsWith(".cs", StringComparison.OrdinalIgnoreCase))
            {
                var normalized = NormalizePath(arg, repoRoot, projectDirectory);
                sourceFiles.Add(normalized);
                var diskPath = Path.IsPathRooted(arg)
                    ? arg
                    : Path.GetFullPath(Path.Combine(projectDirectory, arg));
                sourceFileOriginalPaths.TryAdd(normalized, diskPath);
            }
        }

        if (assemblyName is null)
            return null;

        // Determine if this is a reference assembly by checking the project
        // directory or output path for a "/ref/" segment.
        var isRef = projectDirectory.Contains("/ref/") || projectDirectory.Contains("/ref\\")
            || (outputPath?.Contains("/ref/") == true) || (outputPath?.Contains("/ref\\") == true);

        return new ManagedCompilationRecord
        {
            AssemblyName = assemblyName,
            SourceFiles = sourceFiles,
            SourceFileOriginalPaths = sourceFileOriginalPaths,
            Defines = defines,
            References = references,
            ReferencePaths = referencePaths,
            Analyzers = analyzers,
            Flags = flags,
            TargetType = targetType,
            LangVersion = langVersion,
            BuildSystem = "msbuild",
            OutputPath = outputPath ?? "",
            IsReferenceAssembly = isRef,
        };
    }

    /// <summary>
    /// Split a command-line string into individual arguments, respecting
    /// double-quoted segments (quotes are stripped from the result).
    /// </summary>
    internal static List<string> SplitCommandLine(string commandLine)
    {
        var args = new List<string>();
        var sb = new StringBuilder();
        bool inQuote = false;

        for (int i = 0; i < commandLine.Length; i++)
        {
            char c = commandLine[i];

            if (c == '"')
            {
                inQuote = !inQuote;
            }
            else if (!inQuote && char.IsWhiteSpace(c))
            {
                if (sb.Length > 0)
                {
                    args.Add(sb.ToString());
                    sb.Clear();
                }
            }
            else
            {
                sb.Append(c);
            }
        }

        if (sb.Length > 0)
            args.Add(sb.ToString());

        return args;
    }

    private static string NormalizePath(string path, string repoRoot, string projectDirectory)
    {
        if (string.IsNullOrEmpty(path))
            return path;

        // Resolve relative paths against the project directory (not CWD) so that
        // paths like "System/Collections/Generic/LinkedList.cs" recorded in the
        // binlog relative to the .csproj become fully repo-relative.
        var basePath = Path.IsPathRooted(path) ? path : Path.Combine(projectDirectory, path);
        var normalized = Path.GetFullPath(basePath);
        var root = Path.GetFullPath(repoRoot).TrimEnd('/') + "/";
        if (normalized.StartsWith(root, StringComparison.Ordinal))
            return normalized[root.Length..];

        return normalized;
    }

    /// <summary>
    /// Normalize warning codes to a consistent format.
    /// MSBuild sometimes emits bare numbers (e.g. "1701") and sometimes
    /// prefixed codes (e.g. "CS1701"). Normalize to always use "CS" prefix
    /// for numeric codes and pad CS codes to at least 4 digits so that
    /// CS649 and CS0649 compare as equal.
    /// </summary>
    internal static string NormalizeWarningCode(string code)
    {
        if (code.Length > 0 && char.IsDigit(code[0]))
            return "CS" + code.PadLeft(4, '0');

        // Normalize CSnnnn codes to at least 4 digits (e.g. CS649 → CS0649)
        if (code.StartsWith("CS", StringComparison.Ordinal) && code.Length > 2)
        {
            var numPart = code.AsSpan(2);
            if (numPart.Length > 0 && char.IsDigit(numPart[0]))
                return "CS" + numPart.ToString().PadLeft(4, '0');
        }

        return code;
    }
}
