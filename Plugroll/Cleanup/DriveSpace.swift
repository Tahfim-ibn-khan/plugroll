import Foundation

/// How full the opened drive is, for the storage gauge.
struct DriveSpace: Equatable, Sendable {
    let total: Int64
    let available: Int64

    var used: Int64 { max(0, total - available) }

    var fractionUsed: Double {
        total > 0 ? Double(used) / Double(total) : 0
    }

    /// Reads the drive's size and free space. Nil if the drive isn't answering.
    static func read(_ root: URL) async -> DriveSpace? {
        let space = try? await DriveIO.run(timeout: 5) { () -> DriveSpace? in
            var fresh = root
            fresh.removeAllCachedResourceValues()
            let values = try fresh.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey])
            guard let total = values.volumeTotalCapacity, let available = values.volumeAvailableCapacity else { return nil }
            return DriveSpace(total: Int64(total), available: Int64(available))
        }
        return space ?? nil
    }

    /// Free space on the phone. Edits and compressed videos are made on the phone first,
    /// so a big one needs room here before it goes back to the drive.
    static func phoneAvailable() -> Int64? {
        let values = try? FileManager.default.temporaryDirectory
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}

enum ByteFormat {
    /// "1.2 GB", "340 MB", like Files.
    static func string(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func string(_ bytes: Int) -> String {
        string(Int64(bytes))
    }
}
