import Foundation
import Darwin

enum SocketError: Error, Sendable {
    case create(Int32)
    case bind(Int32)
    case listen(Int32)
    case connect(Int32)
    /// `sockaddr_un.sun_path` is 104 bytes on Darwin, and a path that does not
    /// fit is a configuration problem, not a bug to trap on. See `withAddress`.
    case pathTooLong(length: Int, capacity: Int)
}

/// Builds a `sockaddr_un` for `path` and hands a typed pointer to `body`.
enum UnixSocketAddress {
    /// Throws rather than traps on an over-long path.
    ///
    /// It used to `precondition`, which is a crash — and this sits directly in
    /// the hook's connect path, whose whole contract is to fail OPEN: every
    /// error exits 0 with no stdout so the agent keeps working. A trap is not an
    /// error; it takes the process down, and in the hook's case it would take it
    /// down at exactly the moment an agent is waiting on a decision. `SocketError`
    /// already existed to be thrown into, and both callers already `throws`.
    ///
    /// Reachable, too, without anyone doing anything strange: the socket lives
    /// under the user's home, so a long username plus a sandboxed container path
    /// can approach 104 bytes on its own.
    static func withAddress<R>(
        path: String,
        _ body: (UnsafePointer<sockaddr>, socklen_t) -> R
    ) throws -> R {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path) // 104 on Darwin
        let bytes = Array(path.utf8)
        guard bytes.count < capacity else {
            throw SocketError.pathTooLong(length: bytes.count, capacity: capacity)
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { raw in
            raw.withMemoryRebound(to: CChar.self, capacity: capacity) { dst in
                for (i, b) in bytes.enumerated() { dst[i] = CChar(bitPattern: b) }
                dst[bytes.count] = 0
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        return withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, len) }
        }
    }
}

/// Write every byte of `data` to `fd`, retrying on EINTR. Gives up on any other
/// error (fail-open: a dead peer must never hang us).
@discardableResult
func writeAll(_ fd: Int32, _ data: Data) -> Bool {
    data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
        guard var ptr = raw.baseAddress else { return true }
        var remaining = raw.count
        while remaining > 0 {
            let n = Darwin.write(fd, ptr, remaining)
            if n > 0 {
                ptr = ptr.advanced(by: n)
                remaining -= n
            } else if n < 0 && errno == EINTR {
                continue
            } else {
                return false
            }
        }
        return true
    }
}
