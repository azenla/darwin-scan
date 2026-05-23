import SwiftUI
import Combine
import UniformTypeIdentifiers

extension UTType {
    /// Custom directory-package type for `.darwinscan` documents. Conforms to
    /// `package` so Finder treats it as a single file. Declared in-code only;
    /// Finder will not auto-open these by double-click until we add the same
    /// declarations to Info.plist, but File > Open inside the app works.
    static let darwinScan: UTType = UTType(
        exportedAs: "io.zenla.DarwinScan.scan",
        conformingTo: .package
    )
}

/// SwiftUI reference document — we use a reference type because the store is
/// `@Observable` and we mutate it freely from the scanner (background actor
/// hops on completion). FileDocument's value semantics would force unnecessary
/// copies of large item arrays.
final class ScanDocument: ReferenceFileDocument {
    typealias Snapshot = FileWrapper

    static var readableContentTypes: [UTType] { [.darwinScan] }
    static var writableContentTypes: [UTType] { [.darwinScan] }

    /// We provide the publisher manually because `ScanStore` is `@Observable`
    /// (not `@Published`-backed), so the compiler won't auto-synthesize it.
    let objectWillChange = ObservableObjectPublisher()

    let store: ScanStore

    init() {
        self.store = ScanStore()
    }

    required init(configuration: ReadConfiguration) throws {
        self.store = ScanStore()
        try ScanPackage.load(into: store, from: configuration.file)
    }

    func snapshot(contentType: UTType) throws -> FileWrapper {
        try ScanPackage.makeFileWrapper(from: store)
    }

    func fileWrapper(snapshot: FileWrapper, configuration: WriteConfiguration) throws -> FileWrapper {
        snapshot
    }
}
