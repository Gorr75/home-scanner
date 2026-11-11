import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Replaces a file by writing a sibling temp file and renaming it into place.
/// `rename(2)` swaps the complete temp file over the destination in one step,
/// so a crash keeps either the previous file or the new one, never a half-written one.
public enum AtomicFile {
    public static func write(_ data: Data, to url: URL, fileManager: FileManager = .default) throws {
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let temp = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try data.write(to: temp)
            try replace(temp, with: url)
        } catch {
            try? fileManager.removeItem(at: temp)
            throw error
        }
    }

    private static func replace(_ temp: URL, with destination: URL) throws {
        let result = temp.path.withCString { from in
            destination.path.withCString { to in
                rename(from, to)
            }
        }
        if result != 0 {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [
                NSFilePathErrorKey: destination.path
            ])
        }
    }
}
