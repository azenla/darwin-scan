import ArgumentParser
import Foundation
import DarwinScanCore

@main
struct DarwinScanCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "darwin-scan",
        abstract: "Catalogue the macOS system image to a .darwinscan bundle.",
        discussion: """
            Walks /System, /bin, /sbin, and /usr by default, classifying every
            interesting artifact (Mach-O binaries, .app/.framework bundles,
            launchd plists, dyld_shared_cache, ML models, man pages, …) and
            writing the result to a .darwinscan directory package that the
            DarwinScan GUI can open.
            """,
        subcommands: [Generate.self, Extract.self],
        defaultSubcommand: Generate.self
    )
}

struct Extract: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "extract",
        abstract: "Recreate the captured system directory from a .darwinscan bundle.",
        discussion: """
            Requires that the bundle was generated with --capture-files.
            Items missing their original bytes (no fileBlobRef) are skipped.
            The destination is created if it doesn't exist; existing files
            at conflicting paths are replaced.
            """
    )

    @Argument(
        help: ArgumentHelp(
            "Path to the .darwinscan bundle.",
            valueName: "input.darwinscan"
        ),
        completion: .file(extensions: ["darwinscan"])
    )
    var input: String

    @Argument(
        help: ArgumentHelp(
            "Destination directory for the reconstructed tree.",
            valueName: "destination"
        ),
        completion: .directory
    )
    var destination: String

    @Flag(name: .shortAndLong,
          help: "Suppress per-N-files progress lines; print only the final summary.")
    var quiet: Bool = false

    @MainActor
    mutating func run() async throws {
        let bundleURL = URL(fileURLWithPath: input).standardizedFileURL
        let destURL = URL(fileURLWithPath: destination).standardizedFileURL
        guard bundleURL.pathExtension.lowercased() == "darwinscan" else {
            throw ValidationError("Input must end in .darwinscan, got \(bundleURL.lastPathComponent)")
        }
        FileHandle.standardError.write(Data("Extracting: \(bundleURL.path) -> \(destURL.path)\n".utf8))
        let quietFlag = quiet
        var opts = DarwinScanCore.Extract.Options()
        if quietFlag {
            opts.progressEvery = 0
        }
        let started = Date()
        let summary = try DarwinScanCore.Extract.run(
            bundleURL: bundleURL,
            destination: destURL,
            options: opts
        )
        let elapsed = Date().timeIntervalSince(started)
        let line = String(
            format: "Done. %.1fs elapsed. Wrote %d files (%@), skipped %d.\n",
            elapsed, summary.written, ByteFormat.string(summary.bytesWritten), summary.skipped
        )
        FileHandle.standardError.write(Data(line.utf8))
    }
}

struct Generate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "generate",
        abstract: "Run a scan and save it as a .darwinscan bundle."
    )

    @Argument(
        help: ArgumentHelp(
            "Output path for the .darwinscan bundle.",
            valueName: "output.darwinscan"
        ),
        completion: .file(extensions: ["darwinscan"])
    )
    var output: String

    @Option(
        name: [.long, .customShort("r")],
        parsing: .upToNextOption,
        help: "Scan roots. Defaults to /System, /bin, /sbin, /usr.",
        completion: .directory
    )
    var roots: [String] = []

    @Option(
        name: [.long, .customShort("x")],
        parsing: .upToNextOption,
        help: "Path prefixes to exclude. Replaces (not appends to) defaults when set."
    )
    var exclude: [String] = []

    @Flag(name: .long, inversion: .prefixedNo,
          help: "Follow symbolic links during traversal.")
    var followSymlinks: Bool = false

    @Flag(name: .long, inversion: .prefixedNo,
          help: "SHA-256 every file. Disable for a fast structural scan.")
    var hashFiles: Bool = true

    @Flag(name: .long, inversion: .prefixedNo,
          help: "Run /usr/bin/strings on every Mach-O and store the output as a blob.")
    var extractStrings: Bool = false

    @Option(name: .long, help: "Minimum string length when extracting (strings -n).")
    var stringsMinLength: Int = 6

    @Flag(name: .long, inversion: .prefixedNo, help: "Parse man pages.")
    var indexManPages: Bool = true

    @Flag(name: .long, inversion: .prefixedNo,
          help: "Inspect localizations (.strings/.stringsdict/.lproj).")
    var inspectLocalizations: Bool = true

    @Flag(name: .long, inversion: .prefixedNo,
          help: "Skip non-English .lproj subtrees and non-English .strings files.")
    var englishLocalizationsOnly: Bool = false

    @Flag(name: .long, inversion: .prefixedNo,
          help: "Inspect .app bundles (Info.plist + icon extraction).")
    var inspectAppBundles: Bool = true

    @Flag(name: .long, inversion: .prefixedNo,
          help: "Inspect ML models (.mlmodel/.mlpackage/.mlmodelc).")
    var inspectMLModels: Bool = true

    @Flag(name: .long, inversion: .prefixedNo,
          help: "Inspect dyld_shared_cache_* files.")
    var inspectDyldCache: Bool = true

    @Option(name: .long, help: "Maximum file size (bytes) to fully read for inspections.")
    var maxInspectFileSize: Int64 = 256 * 1024 * 1024

    @Flag(name: .long, inversion: .prefixedNo,
          help: "Extract exported / imported symbols and Obj-C / Swift class names from every Mach-O binary.")
    var extractSymbols: Bool = true

    @Flag(name: .long, inversion: .prefixedNo,
          help: "Copy the bytes of every classified file into the bundle's content-addressed blob store. Required by `darwin-scan extract`. (Default on.)")
    var captureFiles: Bool = true

    @Option(name: .long, help: "Maximum file size (bytes) that --capture-files will pull into the blob store.")
    var maxCaptureFileSize: Int64 = 256 * 1024 * 1024

    @Flag(name: .shortAndLong,
          help: "Suppress per-tick progress; print one final summary line.")
    var quiet: Bool = false

    @MainActor
    mutating func run() async throws {
        let url = URL(fileURLWithPath: output).standardizedFileURL
        guard url.pathExtension.lowercased() == "darwinscan" else {
            throw ValidationError("Output must end in .darwinscan, got \(url.lastPathComponent)")
        }

        var options = ScanOptions()
        if !roots.isEmpty { options.roots = roots }
        if !exclude.isEmpty { options.excludedPrefixes = exclude }
        options.followSymlinks = followSymlinks
        options.hashFiles = hashFiles
        options.extractStrings = extractStrings
        options.stringsMinLength = stringsMinLength
        options.indexManPages = indexManPages
        options.inspectLocalizations = inspectLocalizations
        options.englishLocalizationsOnly = englishLocalizationsOnly
        options.inspectAppBundles = inspectAppBundles
        options.inspectMLModels = inspectMLModels
        options.inspectDyldCache = inspectDyldCache
        options.maxInspectFileSize = maxInspectFileSize
        options.extractSymbols = extractSymbols
        options.captureFiles = captureFiles
        options.maxCaptureFileSize = maxCaptureFileSize

        let started = Date()
        let isTTY = isatty(fileno(stderr)) != 0
        let quietFlag = quiet
        FileHandle.standardError.write(Data("Scanning: \(options.roots.joined(separator: ", "))\n".utf8))
        FileHandle.standardError.write(Data("Output:   \(url.path)\n".utf8))

        try await CommandLineRunner.runScan(
            options: options,
            outputBundleURL: url,
            progressHandler: { update in
                if quietFlag { return }
                renderProgress(update, isTTY: isTTY)
            }
        )

        if !quietFlag && isTTY {
            FileHandle.standardError.write(Data("\r\u{001B}[K".utf8))
        }
        let elapsed = Date().timeIntervalSince(started)
        let summary = String(
            format: "Done. %.1fs elapsed. Bundle written to %@\n",
            elapsed, url.path
        )
        FileHandle.standardError.write(Data(summary.utf8))
    }
}

/// Render one progress update to stderr. On TTYs we overwrite the previous
/// line with `\r` + clear-to-eol; otherwise we print plain lines.
private func renderProgress(_ update: CommandLineRunner.ProgressUpdate, isTTY: Bool) {
    let line = "[\(update.phase.rawValue)] visited \(update.filesVisited) · inspected \(update.filesInspected) · items \(update.itemsFound)"
    if isTTY {
        let out = "\r\u{001B}[K" + line
        FileHandle.standardError.write(Data(out.utf8))
    } else {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}
