import Foundation

/// Live progress for an in-flight scan. The scanner owns this struct and
/// emits whole snapshots — never partial updates from multiple sources.
/// That's the rule that prevents counter "flapping": if two sinks both
/// wrote to different fields and replaced the struct, fields one sink
/// didn't touch would zero out on the other's write.
public nonisolated struct ScanProgress: Sendable, Equatable {
    public var phase: Phase = .idle
    public var filesVisited: Int = 0
    public var filesInspected: Int = 0
    public var bytesHashed: Int64 = 0
    public var startedAt: Date?
    public var itemsFound: Int = 0
    public var perCategoryCounts: [ItemCategory: Int] = [:]
    public var inFlightPaths: [String] = []
    public var workerCount: Int = 0
    /// How many workers are actually busy right now. Distinct from
    /// `inFlightPaths.count`: the analyzer shows a rolling window of recent
    /// paths for context but reports its true in-flight task count here.
    public var activeWorkers: Int = 0
    public var lastError: String?

    public enum Phase: String, Sendable, Equatable {
        case idle
        case enumerating
        case importing
        case analyzing
        case inspecting  // legacy alias for analyzing
        case writing
        case done
        case failed
    }

    public init(
        phase: Phase = .idle,
        filesVisited: Int = 0,
        filesInspected: Int = 0,
        bytesHashed: Int64 = 0,
        startedAt: Date? = nil,
        itemsFound: Int = 0,
        perCategoryCounts: [ItemCategory: Int] = [:],
        inFlightPaths: [String] = [],
        workerCount: Int = 0,
        activeWorkers: Int = 0,
        lastError: String? = nil
    ) {
        self.phase = phase
        self.filesVisited = filesVisited
        self.filesInspected = filesInspected
        self.bytesHashed = bytesHashed
        self.startedAt = startedAt
        self.itemsFound = itemsFound
        self.perCategoryCounts = perCategoryCounts
        self.inFlightPaths = inFlightPaths
        self.workerCount = workerCount
        self.activeWorkers = activeWorkers
        self.lastError = lastError
    }
}
