import Foundation
import SQLite3

/// Reconstructs the original system tree from a `.darwinscan` bundle's
/// captured file blobs. The bundle must have been produced with
/// `--capture-files`; items without a `fileBlobRef` are skipped (we know the
/// path but not the bytes).
///
/// ## Output layout
///
/// Items are written verbatim at `destination + item.path`. So
/// `/bin/ls` from the source goes to `destination/bin/ls`. The destination
/// directory is created if it doesn't exist; existing files at the target
/// path are overwritten.
///
/// ## What's preserved
///
/// - File contents (byte-exact via blob copy).
/// - Modification time (`mtime`) from the item record.
/// - The executable bit (if it looks like an executable category).
///
/// What is NOT preserved:
///
/// - File ownership (uid/gid). We'd need root to set these and the scanner
///   doesn't record them anyway.
/// - Extended attributes / xattrs — the inspector doesn't capture them.
/// - Symlinks, directories, and other non-regular-file entries beyond
///   their classified-item form. Bundles (`.app` / `.framework`) are not
///   reconstructed as wrappers; their member files are extracted as
///   ordinary regular files at their original nested paths.
///
/// Returns the number of files successfully written and the number skipped
/// (for any reason: missing blob, missing path, IO error).
public nonisolated enum Extract {

    public struct Summary: Sendable {
        public let written: Int
        public let skipped: Int
        public let bytesWritten: Int64

        public init(written: Int, skipped: Int, bytesWritten: Int64) {
            self.written = written
            self.skipped = skipped
            self.bytesWritten = bytesWritten
        }
    }

    public struct Options: Sendable {
        /// Print a progress line every N files written. Set to 0 to disable.
        public var progressEvery: Int = 500
        /// Optional sink for progress lines; defaults to stderr.
        public var progressSink: (@Sendable (String) -> Void)?

        public init(progressEvery: Int = 500, progressSink: (@Sendable (String) -> Void)? = nil) {
            self.progressEvery = progressEvery
            self.progressSink = progressSink
        }
    }

    public enum ExtractError: Error, CustomStringConvertible {
        case bundleMissingDatabase(URL)
        case openDatabase(String)

        public var description: String {
            switch self {
            case .bundleMissingDatabase(let url):
                return "Extract: bundle has no data.db at \(url.path)"
            case .openDatabase(let m):
                return "Extract: failed to open database — \(m)"
            }
        }
    }

    /// Runs the extraction. `bundleURL` is the `.darwinscan` directory;
    /// `destination` is where the reconstructed tree should go.
    public static func run(
        bundleURL: URL,
        destination: URL,
        options: Options = Options()
    ) throws -> Summary {
        let dbURL = bundleURL.appendingPathComponent(ScanPackage.databaseFilename)
        guard FileManager.default.fileExists(atPath: dbURL.path) else {
            throw ExtractError.bundleMissingDatabase(dbURL)
        }
        let blobsDir = bundleURL.appendingPathComponent(ScanPackage.blobsDirectory)

        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        // Open the database read-only — we don't want WAL recovery to dirty
        // the bundle on extraction. SQLite makes this opt-in via the URI
        // syntax with mode=ro.
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        let openRC = sqlite3_open_v2(dbURL.path, &db, flags, nil)
        guard openRC == SQLITE_OK, let db else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let db { sqlite3_close_v2(db) }
            throw ExtractError.openDatabase("sqlite3_open_v2 -> \(openRC): \(msg)")
        }
        defer { sqlite3_close_v2(db) }

        var stmt: OpaquePointer?
        defer { if let stmt { sqlite3_finalize(stmt) } }
        // Read just what we need; no JSON decode required.
        let sql = """
            SELECT path, file_blob_ref, modified_at, category
            FROM items
            WHERE file_blob_ref IS NOT NULL
            ORDER BY path;
            """
        let prepRC = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard prepRC == SQLITE_OK, let stmt else {
            throw ExtractError.openDatabase("sqlite3_prepare_v2 -> \(prepRC)")
        }

        var written = 0
        var skipped = 0
        var bytes: Int64 = 0
        let fm = FileManager.default

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let pathC = sqlite3_column_text(stmt, 0),
                  let refC  = sqlite3_column_text(stmt, 1) else {
                skipped += 1
                continue
            }
            let originalPath = String(cString: pathC)
            let ref          = String(cString: refC)
            let mtime: Date? = sqlite3_column_type(stmt, 2) == SQLITE_NULL
                ? nil
                : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2))
            let category: String = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? "other"

            // Strip any leading slash so the original absolute path appends
            // cleanly under destination/.
            let relative = originalPath.hasPrefix("/") ? String(originalPath.dropFirst()) : originalPath
            let dst = destination.appendingPathComponent(relative)

            // Locate the source blob: blobs/<2-char-prefix>/<ref>.bin where
            // the prefix is the first two chars of the hash portion of the
            // ref (skip the `file-` hint).
            let hashPart: String = {
                if let dash = ref.firstIndex(of: "-") {
                    return String(ref[ref.index(after: dash)...])
                }
                return ref
            }()
            let prefix = String(hashPart.prefix(2))
            let blobURL = blobsDir
                .appendingPathComponent(prefix)
                .appendingPathComponent("\(ref).bin")
            guard fm.fileExists(atPath: blobURL.path) else {
                skipped += 1
                continue
            }

            do {
                try fm.createDirectory(
                    at: dst.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if fm.fileExists(atPath: dst.path) {
                    try fm.removeItem(at: dst)
                }
                try fm.copyItem(at: blobURL, to: dst)
                if let mtime {
                    try? fm.setAttributes([.modificationDate: mtime], ofItemAtPath: dst.path)
                }
                // Anything we classified as `.executable` gets +x. Mach-O
                // executables we recognise as such are very rarely shipped
                // without the bit set anyway; we set it explicitly here in
                // case the destination filesystem doesn't preserve mode on
                // copyItem (it should — APFS does — but defensive).
                if category == "executable" {
                    let attrs = (try? fm.attributesOfItem(atPath: dst.path)) ?? [:]
                    if let perm = attrs[.posixPermissions] as? NSNumber {
                        let m = perm.uint16Value | 0o111
                        try? fm.setAttributes([.posixPermissions: NSNumber(value: m)], ofItemAtPath: dst.path)
                    }
                    _ = attrs
                }
                let size = (try? fm.attributesOfItem(atPath: dst.path))?[.size] as? NSNumber
                bytes += Int64(size?.intValue ?? 0)
                written += 1

                if options.progressEvery > 0, written % options.progressEvery == 0 {
                    let line = "wrote \(written) files (\(ByteFormat.string(bytes)))…"
                    if let sink = options.progressSink {
                        sink(line)
                    } else {
                        FileHandle.standardError.write(Data((line + "\n").utf8))
                    }
                }
            } catch {
                skipped += 1
            }
        }

        return Summary(written: written, skipped: skipped, bytesWritten: bytes)
    }
}
