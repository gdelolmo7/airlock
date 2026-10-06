import Foundation

/// The status-line side-channel: Claude Code pipes a JSON payload (context,
/// cost, `rate_limits`, …) to the configured statusLine command on every
/// render. Our bridge caches the rate-limit windows for the notch, then
/// CHAINS to the user's original status line so their display is untouched —
/// we borrow the channel, we don't take it.
public enum StatusLineBridge {
    /// Process one invocation: cache usage (when present), then return the
    /// bytes to print — the chained original's output, or empty. Fail-open
    /// like every hook path: a broken chain must never break the status line
    /// worse than printing nothing.
    /// - Parameter timeout: how long the chained command gets. Injectable so a
    ///   test can hang one on purpose without waiting out the real deadline;
    ///   the hook never passes it.
    public static func process(
        input: Data,
        cacheURL: URL,
        namesURL: URL = SessionNameCache.defaultURL(),
        chainCommandB64: String?,
        timeout: TimeInterval = 3
    ) -> Data {
        if let snapshot = UsageSnapshot.parse(statusLineJSON: input, at: Date()) {
            try? snapshot.save(to: cacheURL)
        }
        // session_name = /rename value or the AI-generated conversation title.
        if let root = try? JSONSerialization.jsonObject(with: input) as? [String: Any],
           let sessionID = root["session_id"] as? String,
           let name = root["session_name"] as? String, !name.isEmpty {
            SessionNameCache.record(sessionID: sessionID, name: name, at: Date(), url: namesURL)
        }
        guard let chainCommandB64,
              let commandData = Data(base64Encoded: chainCommandB64),
              let command = String(data: commandData, encoding: .utf8) else {
            return Data()
        }
        return (try? run(command: command, stdin: input, timeout: timeout)) ?? Data()
    }

    /// Every pipe call here is the throwing kind. The legacy `FileHandle`
    /// calls raise an Objective-C exception on an I/O error instead, which
    /// Swift cannot catch: in the hook that is a crash, where this promises
    /// to fail open.
    private static func run(command: String, stdin: Data,
                            timeout: TimeInterval) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let inPipe = Pipe(), outPipe = Pipe()
        // Nothing obliges the command to read its input — plenty of status
        // lines never do — and once one has exited, the write below has no
        // reader. A write to a pipe with no reader raises SIGPIPE, and its
        // default is to kill the writer: the hook, mid-render, taking the
        // user's status line with it. Switched off for this one descriptor,
        // the pipe twin of the socket transport's `SO_NOSIGPIPE`, so the write
        // fails with EPIPE instead. Deliberately not `signal(SIGPIPE, SIG_IGN)`:
        // that changes the whole process, and only protects a process that
        // remembered to call it — this protects any caller of the bridge.
        _ = fcntl(inPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        // Deadline, because this runs the USER'S OWN shell command — an
        // arbitrary `sh -c` from their Claude settings — on a path Claude Code
        // invokes on every render. A command that blocks (a prompt, a network
        // call, a wedged mount) would otherwise hold this forever. Terminating
        // closes the pipes, which is what releases the write and the read
        // below. Armed BEFORE the write: an input bigger than the pipe's
        // buffer, fed to a command that neither reads nor exits, used to block
        // the write with no deadline running yet.
        let deadline = DispatchWorkItem { process.terminate() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: deadline)
        // A failed write (the EPIPE above) must not cost the output: a command
        // that ignored its input may still have printed a status line.
        try? inPipe.fileHandleForWriting.write(contentsOf: stdin)
        try? inPipe.fileHandleForWriting.close()
        // A failed read prints nothing, exactly as a command that printed
        // nothing does.
        let output = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
        process.waitUntilExit()
        deadline.cancel()
        return output
    }
}
