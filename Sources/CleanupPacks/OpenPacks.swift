import Foundation
import CleanupCore

/// Process-local record of the pack directories open cleaners hold, keyed by resolved path.
/// `PackInstaller.remove` refuses a held directory; cleaners in other processes are invisible here.
/// `@unchecked Sendable`: every field is read and written under `lock`.
package final class OpenPacks: @unchecked Sendable {
    package static let shared = OpenPacks()
    private let lock = NSLock()
    private var holds: [String: Int] = [:]

    /// Marks `directory` held until the returned hold is released or deallocated.
    package func hold(_ directory: URL) -> PackHold {
        lock.withLock { holds[directory.path, default: 0] += 1 }
        return PackHold(registry: self, key: directory.path)
    }

    /// Runs `body` with the hold table locked, so a cleaner cannot start holding `directory` meanwhile.
    func whileUnheld(_ directory: URL, _ body: () throws -> Void) throws {
        try lock.withLock {
            guard holds[directory.path, default: 0] == 0 else {
                throw CleanupError.unavailable("an open Cleaner holds the pack at \(directory.lastPathComponent)")
            }
            try body()
        }
    }

    fileprivate func release(_ key: String) {
        lock.withLock {
            if let count = holds[key], count > 1 { holds[key] = count - 1 } else { holds[key] = nil }
        }
    }
}

/// Releases exactly once, on `release()` or deallocation, whichever comes first.
package final class PackHold: @unchecked Sendable {
    private let registry: OpenPacks
    private let key: String
    private let released = NSLock()
    private var done = false

    fileprivate init(registry: OpenPacks, key: String) { self.registry = registry; self.key = key }
    deinit { release() }

    package func release() {
        let first = released.withLock { let was = done; done = true; return !was }
        if first { registry.release(key) }
    }
}
