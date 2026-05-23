import Foundation

/// Live progress for an in-flight scan. The scanner mutates this on its own
/// actor; the UI reads a `Sendable` snapshot via `@Observable` indirection in
/// ScanController.
struct ScanProgress: Sendable, Equatable {
    var phase: Phase = .idle
    var currentPath: String = ""
    var filesVisited: Int = 0
    var filesInspected: Int = 0
    var bytesHashed: Int64 = 0
    var startedAt: Date?
    var itemsFound: Int = 0
    /// Per-category running tally — drives sidebar counts updating in real time.
    var perCategoryCounts: [ItemCategory: Int] = [:]
    var lastError: String?

    enum Phase: String, Sendable, Equatable {
        case idle
        case enumerating       // walking directories
        case inspecting        // inspectors running per file
        case writing           // saving to document
        case done
        case failed
    }
}
