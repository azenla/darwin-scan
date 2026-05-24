import Foundation
import CryptoKit

public nonisolated enum Hash {
    /// SHA-256 of a file, computed via CryptoKit incrementally so we don't load
    /// gigabyte-class files (think dyld_shared_cache) into memory.
    public static func sha256(of url: URL, chunkSize: Int = 1 << 20) -> String? {
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

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
    }
}

/// Deterministic identity for a `ScanItem`. Same `(path, sha256)` pair
/// always produces the same UUID, so re-scans of unchanged content reuse
/// the existing row (snapshot dedup) and a change in `sha256` at the same
/// path produces a *different* id (multi-version diff backbone).
///
/// When `sha256` is nil — the file wasn't hashed, or the item is a bundle
/// wrapper — the id is derived from the path alone. That gives bundles
/// stable identity across scans (their wrapper rarely changes); content
/// changes inside the bundle show up as diffs in the *child* items.
///
/// Internally, hashes `"<scheme>::<path>::<sha256-or-marker>"` with SHA-256
/// and reformats the first 16 bytes into a UUIDv4-shaped value. Stable
/// across runs of the same darwin-scan binary, and across machines, as
/// long as the inputs match.
public nonisolated enum ItemIdentity {
    /// Derive the deterministic UUID for an item at `path` with `sha256`.
    /// Pass `bundlePathOnly: true` when calling for a bundle wrapper —
    /// makes the id depend only on the path so the bundle row is stable
    /// even as its children change.
    public static func uuid(path: String, sha256: String?, bundlePathOnly: Bool = false) -> UUID {
        let marker: String
        if let sha256 {
            marker = sha256
        } else if bundlePathOnly {
            marker = "bundle"
        } else {
            // No way to dedup — return a random UUID. Caller is responsible
            // for understanding this loses cross-scan identity.
            return UUID()
        }
        let key = "darwinscan-itemid::\(path)::\(marker)"
        let digest = SHA256.hash(data: Data(key.utf8))
        var bytes: [UInt8] = []
        bytes.reserveCapacity(16)
        for (i, b) in digest.enumerated() where i < 16 {
            bytes.append(b)
        }
        // Stamp the UUIDv4 version + variant bits so the result is a valid
        // RFC4122 UUID. Hashing into a UUID is allowed by the RFC under
        // "name-based" (v5); we tag as v4 here since that's the project's
        // existing default and downstream code doesn't care about version.
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
