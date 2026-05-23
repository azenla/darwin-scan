import Foundation

/// On-disk layout for a `.darwinscan` directory bundle:
///
/// ```
/// MyScan.darwinscan/
///   metadata.json        — package version, system info, options, timestamps
///   items.json           — manifest: array of every ScanItem
///   blobs/
///     <2-char-prefix>/
///       <ref>.bin        — content-addressed payload
/// ```
///
/// The blob layout mirrors git's loose-object scheme — keeps directory sizes
/// reasonable when there are tens of thousands of small icons/strings dumps.
enum ScanPackage {
    static let metadataFilename = "metadata.json"
    static let itemsFilename    = "items.json"
    static let blobsDirectory   = "blobs"
    static let packageVersion   = 1

    struct Metadata: Codable {
        var version: Int
        var systemInfo: SystemInfo?
        var options: ScanOptions
        var lastScanStarted: Date?
        var lastScanCompleted: Date?
    }

    struct Payload: Codable {
        var items: [ScanItem]
    }

    /// Builds a `FileWrapper` directory representation of the current store.
    static func makeFileWrapper(from store: ScanStore) throws -> FileWrapper {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let metadata = Metadata(
            version: packageVersion,
            systemInfo: store.systemInfo,
            options: store.options,
            lastScanStarted: store.lastScanStarted,
            lastScanCompleted: store.lastScanCompleted
        )
        let metadataData = try encoder.encode(metadata)

        let payload = Payload(items: Array(store.items.values))
        let payloadData = try encoder.encode(payload)

        var contents: [String: FileWrapper] = [
            metadataFilename: FileWrapper(regularFileWithContents: metadataData),
            itemsFilename:    FileWrapper(regularFileWithContents: payloadData)
        ]

        if !store.blobs.isEmpty {
            var prefixes: [String: [String: FileWrapper]] = [:]
            for (ref, data) in store.blobs {
                let prefix = String(blobHashPart(ref).prefix(2))
                prefixes[prefix, default: [:]]["\(ref).bin"] = FileWrapper(regularFileWithContents: data)
            }
            var subdirs: [String: FileWrapper] = [:]
            for (prefix, files) in prefixes {
                subdirs[prefix] = FileWrapper(directoryWithFileWrappers: files)
            }
            contents[blobsDirectory] = FileWrapper(directoryWithFileWrappers: subdirs)
        }

        let root = FileWrapper(directoryWithFileWrappers: contents)
        root.preferredFilename = nil
        return root
    }

    /// Reads a directory FileWrapper back into a fresh `ScanStore`.
    static func load(into store: ScanStore, from wrapper: FileWrapper) throws {
        guard wrapper.isDirectory, let children = wrapper.fileWrappers else {
            throw NSError(domain: "ScanPackage", code: 1, userInfo: [NSLocalizedDescriptionKey: "Not a package"])
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        guard let metaWrapper = children[metadataFilename],
              let metaData = metaWrapper.regularFileContents else {
            throw NSError(domain: "ScanPackage", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing metadata.json"])
        }
        let metadata = try decoder.decode(Metadata.self, from: metaData)

        var items: [ScanItem] = []
        if let itemsWrapper = children[itemsFilename],
           let itemsData = itemsWrapper.regularFileContents {
            items = try decoder.decode(Payload.self, from: itemsData).items
        }

        var blobs: [String: Data] = [:]
        if let blobsRoot = children[blobsDirectory], let prefixes = blobsRoot.fileWrappers {
            for (_, prefixWrapper) in prefixes {
                guard prefixWrapper.isDirectory, let files = prefixWrapper.fileWrappers else { continue }
                for (filename, file) in files {
                    guard filename.hasSuffix(".bin"), let data = file.regularFileContents else { continue }
                    let ref = String(filename.dropLast(4))
                    blobs[ref] = data
                }
            }
        }

        store.load(
            items: items,
            blobs: blobs,
            systemInfo: metadata.systemInfo,
            options: metadata.options,
            lastScanStarted: metadata.lastScanStarted,
            lastScanCompleted: metadata.lastScanCompleted
        )
    }

    /// Strips an optional "hint-" prefix from a blob ref so we can extract the
    /// raw hash to use as a sharded directory prefix.
    private static func blobHashPart(_ ref: String) -> String {
        if let dash = ref.firstIndex(of: "-") {
            return String(ref[ref.index(after: dash)...])
        }
        return ref
    }
}
