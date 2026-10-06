import Foundation
import Darwin

/// Client side, used by the hook CLI. Connects, sends envelopes, and — for a
/// blocking permission gate — waits up to `timeout` for a single directive.
/// Every failure path returns without throwing to the agent's flow (fail-open).
public enum UnixSocketClient {
    public static func send(
        path: String,
        envelopes: [BridgeEnvelope],
        awaitDirective: Bool,
        timeout: TimeInterval
    ) throws -> HookDirective? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.create(errno) }
        defer { Darwin.close(fd) }

        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        let connected = try UnixSocketAddress.withAddress(path: path) { connect(fd, $0, $1) }
        guard connected == 0 else { throw SocketError.connect(errno) }

        for envelope in envelopes {
            let data = try BridgeCodec.encodeLine(envelope)
            guard writeAll(fd, data) else { return nil }
        }

        guard awaitDirective else { return nil }
        return readDirective(on: fd, timeout: timeout)
    }

    private static func readDirective(on fd: Int32, timeout: TimeInterval) -> HookDirective? {
        var buffer = Data()
        let capacity = 8 * 1024
        var chunk = [UInt8](repeating: 0, count: capacity)
        let deadline = Date().addingTimeInterval(timeout)

        while true {
            let remainingMS = Int32(max(0, deadline.timeIntervalSinceNow * 1000))
            if remainingMS == 0 { return nil }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, remainingMS)
            if ready <= 0 { return nil } // timeout or error → fail open

            let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, capacity) }
            if n <= 0 { return nil }
            buffer.append(contentsOf: chunk[0..<n])

            guard let envelopes = try? BridgeCodec.drainLines(BridgeEnvelope.self, from: &buffer) else {
                return nil
            }
            for envelope in envelopes {
                switch envelope {
                case .directive(let directive): return directive
                case .ack: return nil
                default: continue
                }
            }
        }
    }
}
