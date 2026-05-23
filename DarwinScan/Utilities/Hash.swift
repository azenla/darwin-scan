import Foundation
import CryptoKit

nonisolated enum Hash {
    /// SHA-256 of a file, computed via CryptoKit incrementally so we don't load
    /// gigabyte-class files (think dyld_shared_cache) into memory.
    static func sha256(of url: URL, chunkSize: Int = 1 << 20) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data: Data
            do {
                guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else { break }
                data = chunk
            } catch {
                return nil
            }
            hasher.update(data: data)
        }
        return hasher.finalize().compactMap { String(format: "%02x", $0) }.joined()
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
    }
}
