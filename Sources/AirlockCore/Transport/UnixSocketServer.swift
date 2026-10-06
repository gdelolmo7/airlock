import Foundation
import Darwin

/// A live client connection. Thread-safe writes; identity-comparable so the
/// bridge can route a directive back to the exact hook that is waiting.
public final class ClientConnection: @unchecked Sendable, Hashable {
    public let id: Int
    let fd: Int32
    private let writeLock = NSLock()
    private var closed = false

    init(id: Int, fd: Int32) {
        self.id = id
        self.fd = fd
    }

    public func send(_ envelope: BridgeEnvelope) {
        guard let data = try? BridgeCodec.encodeLine(envelope) else { return }
        writeLock.lock()
        defer { writeLock.unlock() }
        guard !closed else { return }
        writeAll(fd, data)
    }

    func close() {
        writeLock.lock()
        defer { writeLock.unlock() }
        guard !closed else { return }
        closed = true
        Darwin.close(fd)
    }

    public static func == (lhs: ClientConnection, rhs: ClientConnection) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// What the transport saw. Bytes and identity, nothing else.
///
/// **Never give this a session id, a gate, or a verdict.** The moment it
/// carries domain meaning, this layer stops "moving bytes only" and the
/// `@unchecked Sendable` exemption CLAUDE.md grants it stops applying.
enum TransportEvent: Sendable {
    case envelope(BridgeEnvelope, ClientConnection)
    case disconnected(ClientConnection)
}

/// Unix-domain socket listener.
///
/// Transport isolation is lock/thread-based by necessity — blocking POSIX I/O
/// can't live on an actor's cooperative executor without starving it. Domain
/// state lives in `BridgeServer` (an actor); this class only moves bytes.
///
/// Every mutable field is behind `lock`. That is now true, and it was not: two
/// `var` callbacks used to sit outside it, written from the actor and read from
/// every reader thread. Nothing crashed, because `BridgeServer.start()` happened
/// to assign both before the first thread existed — thread creation supplied the
/// happens-before edge. That is a temporal argument, not a structural one, and
/// it made the comment above a claim about three of five properties.
///
/// A stream fixes more than the race. Two independent callbacks meant two
/// independent `Task`s on the actor with no ordering between them, so a
/// disconnect could be processed before the payload that arrived first —
/// registering a gate on a connection already gone. One stream, drained by one
/// task, makes ordering a property of the type rather than of the scheduler:
/// `readLoop` yields envelopes and then `drop` yields the disconnect, in program
/// order, on the same thread.
final class UnixSocketServer: @unchecked Sendable {
    let path: String
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var connections: [Int: ClientConnection] = [:]
    private var nextID = 0

    /// **`.unbounded` deliberately.** Dropping a `.disconnected` strands the
    /// gate it belonged to, and a stranded gate is a card that never goes away —
    /// exactly the bug `BridgeServer.forget` was fixed for, minus the trail. The
    /// producer is a blocking POSIX thread that cannot be suspended for
    /// back-pressure without stalling the read loop mid-frame, so bounding this
    /// buffer can only ever mean silently discarding.
    let events: AsyncStream<TransportEvent>
    private let continuation: AsyncStream<TransportEvent>.Continuation

    init(path: String) {
        self.path = path
        (events, continuation) = AsyncStream.makeStream(
            of: TransportEvent.self, bufferingPolicy: .unbounded)
    }

    func start() throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        unlink(path) // clear a stale socket from a previous run

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.create(errno) }

        let bound = try UnixSocketAddress.withAddress(path: path) { bind(fd, $0, $1) }
        guard bound == 0 else { Darwin.close(fd); throw SocketError.bind(errno) }
        chmod(path, 0o600)
        guard listen(fd, 16) == 0 else { Darwin.close(fd); throw SocketError.listen(errno) }

        lock.lock(); listenFD = fd; lock.unlock()
        Thread.detachNewThread { [weak self] in self?.acceptLoop(fd) }
    }

    func stop() {
        lock.lock()
        let fd = listenFD; listenFD = -1
        let conns = Array(connections.values); connections.removeAll()
        lock.unlock()
        if fd >= 0 { Darwin.close(fd) }
        conns.forEach { $0.close() }
        // After the closes, so every reader thread's `drop` has somewhere to
        // deliver its `.disconnected` — finishing first would swallow exactly
        // the events that end held gates.
        continuation.finish()
        // Intentionally not unlink()-ing here: a newer instance may already own
        // the path. start() clears stale sockets before binding.
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                break // listener closed
            }
            // Peer-credential check: only same-uid processes may talk to a
            // channel that gates command-execution approvals.
            var uid = uid_t(); var gid = gid_t()
            if getpeereid(client, &uid, &gid) != 0 || uid != getuid() {
                Darwin.close(client)
                continue
            }
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

            let conn = register(client)
            Thread.detachNewThread { [weak self] in self?.readLoop(conn) }
        }
    }

    private func register(_ fd: Int32) -> ClientConnection {
        lock.lock()
        let id = nextID; nextID += 1
        let conn = ClientConnection(id: id, fd: fd)
        connections[id] = conn
        lock.unlock()
        return conn
    }

    private func readLoop(_ conn: ClientConnection) {
        var buffer = Data()
        let capacity = 64 * 1024
        var chunk = [UInt8](repeating: 0, count: capacity)
        loop: while true {
            let n = chunk.withUnsafeMutableBytes { read(conn.fd, $0.baseAddress, capacity) }
            switch n {
            case let n where n > 0:
                buffer.append(contentsOf: chunk[0..<n])
                do {
                    let envelopes = try BridgeCodec.drainLines(BridgeEnvelope.self, from: &buffer)
                    for envelope in envelopes { continuation.yield(.envelope(envelope, conn)) }
                } catch {
                    break loop // framing violation → drop the connection
                }
            case 0:
                break loop // EOF
            default:
                if errno == EINTR { continue }
                break loop
            }
        }
        drop(conn)
    }

    /// Close BEFORE signalling, and keep it that way. `BridgeServer.deferGate`
    /// sends a directive to the departing connection and relies on that send
    /// being a no-op; `ClientConnection.send` is a no-op only once `close()` has
    /// set its flag. Signal first and the resolution starts writing to a dead
    /// fd instead.
    private func drop(_ conn: ClientConnection) {
        lock.lock(); connections.removeValue(forKey: conn.id); lock.unlock()
        conn.close()
        continuation.yield(.disconnected(conn))
    }
}
