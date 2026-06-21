import ArgumentParser
import Foundation
import DarwinScanCore

@main
struct DarwinScanCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "darwin-scan",
        abstract: "Catalogue a macOS system image (live system or IPSW) to a .darwinscan bundle.",
        discussion: """
            Two phases: `import` walks the source and captures file bytes
            fast; `analyze` runs the inspectors (Mach-O, symbols, strings,
            bundle metadata) and is re-runnable on a finished snapshot.

            One bundle holds many snapshots — chain IPSWs to diff a macOS
            upgrade, or re-import the current system over time.
            """,
        subcommands: [
            Create.self, Import.self, Analyze.self,
            ListSnapshots.self, DeleteSnapshot.self, Extract.self
        ]
    )
}

// MARK: - create

struct Create: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a new empty .darwinscan bundle."
    )
    @Argument(help: "Path to create.", completion: .file(extensions: ["darwinscan"]))
    var output: String

    @MainActor
    mutating func run() async throws {
        let url = URL(fileURLWithPath: output).standardizedFileURL
        _ = try ScanPackage.createEmpty(at: url)
        FileHandle.standardError.write(Data("Created \(url.path)\n".utf8))
    }
}

// MARK: - import

struct Import: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import",
        abstract: "Run the import phase: walk a source, capture bytes, write a new snapshot.",
        discussion: """
            By default imports the current system (/System, /bin, /sbin, /usr).
            Pass --ipsw <file> to import from an IPSW instead. The new
            snapshot is chained onto whatever's already in the bundle.
            Analysis is NOT run automatically; use `darwin-scan analyze`
            afterwards (or pass --then-analyze).
            """
    )

    @Argument(help: "Target .darwinscan bundle. Created if missing.", completion: .file(extensions: ["darwinscan"]))
    var output: String

    @Option(name: .long, help: "Path to an IPSW. When set, the import source is the IPSW.", completion: .file())
    var ipsw: String?

    @Option(name: [.long, .customShort("r")], parsing: .upToNextOption, help: "Scan roots. Defaults to /System, /bin, /sbin, /usr.", completion: .directory)
    var roots: [String] = []

    @Option(name: [.long, .customShort("x")], parsing: .upToNextOption, help: "Path prefixes to exclude.")
    var exclude: [String] = []

    @Flag(name: .long, help: "Run analysis automatically after import completes.")
    var thenAnalyze: Bool = false

    @Flag(name: .shortAndLong, help: "Print only the final summary line.")
    var quiet: Bool = false

    @MainActor
    mutating func run() async throws {
        let url = URL(fileURLWithPath: output).standardizedFileURL
        guard url.pathExtension.lowercased() == "darwinscan" else {
            throw ValidationError("Output must end in .darwinscan, got \(url.lastPathComponent)")
        }

        var options = ScanOptions()
        if !roots.isEmpty   { options.roots = roots }
        if !exclude.isEmpty { options.excludedPrefixes = exclude }

        let source: any SourceProvider
        if let ipsw = self.ipsw {
            let ipswURL = URL(fileURLWithPath: ipsw).standardizedFileURL
            FileHandle.standardError.write(Data("Preparing IPSW: \(ipswURL.path)\n".utf8))
            let ipswSource = try await IPSWSource.prepare(
                ipswURL: ipswURL,
                options: options,
                progress: { line in
                    FileHandle.standardError.write(Data((line + "\n").utf8))
                }
            )
            for diag in ipswSource.diagnostics {
                FileHandle.standardError.write(Data(("⚠ " + diag + "\n").utf8))
            }
            source = ipswSource
        } else {
            source = CurrentSystemSource(options: options)
        }
        FileHandle.standardError.write(Data("Source: \(source.sourceRef)\n".utf8))
        FileHandle.standardError.write(Data("Output: \(url.path)\n".utf8))

        let started = Date()
        let isTTY = isatty(fileno(stderr)) != 0
        let q = quiet
        try await CommandLineRunner.runImport(
            source: source,
            options: options,
            outputBundleURL: url,
            progressHandler: { update in
                if q { return }
                renderProgress(update, isTTY: isTTY)
            }
        )
        if !q && isTTY { FileHandle.standardError.write(Data("\r\u{001B}[K".utf8)) }
        let elapsed = Date().timeIntervalSince(started)
        FileHandle.standardError.write(Data(String(format: "Import done. %.1fs.\n", elapsed).utf8))

        if thenAnalyze {
            FileHandle.standardError.write(Data("Running analysis…\n".utf8))
            try await CommandLineRunner.runAnalysis(
                bundleURL: url,
                snapshotID: nil,
                options: options,
                progressHandler: { update in
                    if q { return }
                    renderProgress(update, isTTY: isTTY)
                }
            )
            if !q && isTTY { FileHandle.standardError.write(Data("\r\u{001B}[K".utf8)) }
            FileHandle.standardError.write(Data("Analysis done.\n".utf8))
        }
    }
}

// MARK: - analyze

struct Analyze: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "analyze",
        abstract: "Run (or re-run) the analysis phase on a snapshot.",
        discussion: """
            Walks every item in the target snapshot, runs the inspectors
            against captured blob bytes (or the live filesystem when capture
            wasn't on), and refines category + per-category payloads.

            Idempotent: re-running on a snapshot wipes its previous
            analysis output before re-applying. Use this after a `darwin-
            scan` upgrade to take advantage of new inspectors.
            """
    )

    @Argument(help: "Target .darwinscan bundle.", completion: .file(extensions: ["darwinscan"]))
    var bundle: String

    @Option(name: .long, help: "Snapshot id to analyze. Defaults to the latest snapshot.")
    var snapshot: Int64?

    @Flag(name: .long, inversion: .prefixedNo, help: "Run `/usr/bin/strings` and index the output.")
    var extractStrings: Bool = false

    @Flag(name: .long, inversion: .prefixedNo, help: "Extract exported / imported symbols and Obj-C / Swift class names.")
    var extractSymbols: Bool = true

    @Flag(name: .long, inversion: .prefixedNo, help: "Inspect localizations (.strings/.stringsdict/.lproj).")
    var inspectLocalizations: Bool = true

    @Flag(name: .long, inversion: .prefixedNo, help: "Skip non-English .lproj subtrees and non-English .strings files.")
    var englishLocalizationsOnly: Bool = false

    @Flag(name: .long, inversion: .prefixedNo, help: "Inspect ML models.")
    var inspectMLModels: Bool = true

    @Flag(name: .long, inversion: .prefixedNo, help: "Inspect dyld_shared_cache_* files.")
    var inspectDyldCache: Bool = true

    @Flag(name: .long, inversion: .prefixedNo, help: "Parse man pages.")
    var indexManPages: Bool = true

    @Flag(name: .shortAndLong, help: "Print only the final summary line.")
    var quiet: Bool = false

    @MainActor
    mutating func run() async throws {
        let url = URL(fileURLWithPath: bundle).standardizedFileURL
        var options = ScanOptions()
        options.extractStrings = extractStrings
        options.extractSymbols = extractSymbols
        options.inspectLocalizations = inspectLocalizations
        options.englishLocalizationsOnly = englishLocalizationsOnly
        options.inspectMLModels = inspectMLModels
        options.inspectDyldCache = inspectDyldCache
        options.indexManPages = indexManPages

        let started = Date()
        let isTTY = isatty(fileno(stderr)) != 0
        let q = quiet
        try await CommandLineRunner.runAnalysis(
            bundleURL: url,
            snapshotID: snapshot,
            options: options,
            progressHandler: { update in
                if q { return }
                renderProgress(update, isTTY: isTTY)
            }
        )
        if !q && isTTY { FileHandle.standardError.write(Data("\r\u{001B}[K".utf8)) }
        let elapsed = Date().timeIntervalSince(started)
        FileHandle.standardError.write(Data(String(format: "Analysis done in %.1fs.\n", elapsed).utf8))
    }
}

// MARK: - list

struct ListSnapshots: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "snapshots",
        abstract: "List every snapshot in a bundle."
    )

    @Argument(help: "Target .darwinscan bundle.", completion: .file(extensions: ["darwinscan"]))
    var bundle: String

    @MainActor
    mutating func run() async throws {
        let url = URL(fileURLWithPath: bundle).standardizedFileURL
        let snapshots = try CommandLineRunner.listSnapshots(bundleURL: url)
        if snapshots.isEmpty {
            FileHandle.standardError.write(Data("(no snapshots)\n".utf8))
            return
        }
        for snap in snapshots {
            let label = snap.label ?? "—"
            let kind = snap.sourceKind.displayName
            let ref = snap.sourceRef ?? "—"
            let analysis = "\(snap.analysisState.rawValue)\(snap.analyzedAt.map { " @ \(DateFormatter.iso.string(from: $0))" } ?? "")"
            let line = "[\(snap.id)] \(label)\n    source: \(kind) (\(ref))\n    imported: \(DateFormatter.iso.string(from: snap.startedAt))\n    analysis: \(analysis)\n"
            FileHandle.standardOutput.write(Data(line.utf8))
        }
    }
}

// MARK: - delete

struct DeleteSnapshot: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete-snapshot",
        abstract: "Remove a snapshot (and any items it uniquely owned) from a bundle."
    )

    @Argument(help: "Target .darwinscan bundle.", completion: .file(extensions: ["darwinscan"]))
    var bundle: String

    @Option(name: .long, help: "Snapshot id to remove. Use `darwin-scan snapshots` to list ids.")
    var snapshot: Int64

    @MainActor
    mutating func run() async throws {
        let url = URL(fileURLWithPath: bundle).standardizedFileURL
        try CommandLineRunner.deleteSnapshot(bundleURL: url, snapshotID: snapshot)
        FileHandle.standardError.write(Data("Removed snapshot \(snapshot).\n".utf8))
    }
}

// MARK: - extract

struct Extract: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "extract",
        abstract: "Recreate the captured tree from a snapshot."
    )

    @Argument(help: ArgumentHelp("Path to the .darwinscan bundle.", valueName: "input.darwinscan"),
              completion: .file(extensions: ["darwinscan"]))
    var input: String

    @Argument(help: ArgumentHelp("Destination directory.", valueName: "destination"),
              completion: .directory)
    var destination: String

    @Flag(name: .shortAndLong, help: "Suppress per-N-files progress lines.")
    var quiet: Bool = false

    @MainActor
    mutating func run() async throws {
        let bundleURL = URL(fileURLWithPath: input).standardizedFileURL
        let destURL = URL(fileURLWithPath: destination).standardizedFileURL
        guard bundleURL.pathExtension.lowercased() == "darwinscan" else {
            throw ValidationError("Input must end in .darwinscan, got \(bundleURL.lastPathComponent)")
        }
        FileHandle.standardError.write(Data("Extracting: \(bundleURL.path) -> \(destURL.path)\n".utf8))
        var opts = DarwinScanCore.Extract.Options()
        if quiet { opts.progressEvery = 0 }
        let started = Date()
        let summary = try DarwinScanCore.Extract.run(bundleURL: bundleURL, destination: destURL, options: opts)
        let elapsed = Date().timeIntervalSince(started)
        let line = String(
            format: "Done. %.1fs elapsed. Wrote %d files (%@), skipped %d.\n",
            elapsed, summary.written, ByteFormat.string(summary.bytesWritten), summary.skipped
        )
        FileHandle.standardError.write(Data(line.utf8))
    }
}

// MARK: - shared

private func renderProgress(_ update: CommandLineRunner.ProgressUpdate, isTTY: Bool) {
    let line = "[\(update.phase.rawValue)] visited \(update.filesVisited) · inspected \(update.filesInspected) · items \(update.itemsFound)"
    if isTTY {
        FileHandle.standardError.write(Data(("\r\u{001B}[K" + line).utf8))
    } else {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}

private extension DateFormatter {
    static let iso: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()
}
