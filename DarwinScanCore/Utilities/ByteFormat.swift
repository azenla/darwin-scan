import Foundation

public nonisolated enum ByteFormat {
    public static let bytes: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false
        return f
    }()

    public static func string(_ count: Int64) -> String {
        bytes.string(fromByteCount: count)
    }

    public static func compactDate(_ d: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: d)
    }
}
