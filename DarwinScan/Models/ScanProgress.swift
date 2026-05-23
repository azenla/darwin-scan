import Foundation

/// Live progress for an in-flight scan. The scanner owns this struct and
/// emits whole snapshots — never partial updates from multiple sources.
/// That's the rule that prevents counter "flapping": if two sinks both
/// wrote to different fields and replaced the struct, fields one sink
/// didn't touch would zero out on the other's write.
struct ScanProgress: Sendable, Equatable {
    var phase: Phase = .idle
    var filesVisited: Int = 0
    var filesInspected: Int = 0
    var bytesHashed: Int64 = 0
    var startedAt: Date?
    var itemsFound: Int = 0
    /// Per-category running tally — drives sidebar counts updating in real time.
    var perCategoryCounts: [ItemCategory: Int] = [:]
    /// Paths currently being inspected by worker tasks. Length is bounded by
    /// the worker's concurrency window (≈ activeCPUs - 1). Ordering reflects
    /// enqueue order so the UI list is stable.
    var inFlightPaths: [String] = []
    /// Total concurrent workers the scanner is using. Surfaced in the UI as
    /// "Inspecting X / Y in parallel".
    var workerCount: Int = 0
    var lastError: String?

    enum Phase: String, Sendable, Equatable {
        case idle
        case enumerating       // walking directories, no inspections yet
        case inspecting        // inspectors running in parallel
        case writing           // saving to document
        case done
        case failed
    }
}
