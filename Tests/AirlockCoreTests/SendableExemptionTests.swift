import XCTest

/// An allowlist for `@unchecked Sendable`, enforced rather than asserted in prose.
///
/// This exists because a comment tried to do the job and failed. `AudioCapture`
/// said the exemption was "justified here and deliberately nowhere else"; that
/// stopped being true ONE DAY later, when `SystemAudioTap` landed with the same
/// words and a much weaker claim, and nobody noticed for months. A test would
/// have failed that afternoon.
///
/// The criterion lives in CLAUDE.md, Conventions → "Concurrency by the
/// compiler". In short: `@unchecked Sendable` only where an OS boundary invokes
/// our code on a thread
/// we neither own nor can make an actor — blocking POSIX socket I/O, and
/// realtime audio callbacks — and only on a type that holds no domain state, has
/// every mutable field either provably owned by that one thread or covered by
/// the lock, and says in a comment which of the two each field is.
///
/// A count is the wrong criterion: an OS callback cannot be actor-isolated, so
/// the answer is never zero. What matters is which types, and why.
final class SendableExemptionTests: XCTestCase {

    /// Type name → why it is allowed. The reason travels with the entry so the
    /// failure message can carry it: someone under deadline who sees a bare list
    /// deletes the failing line instead of the exemption.
    private static let allowed: [String: String] = [
        "ClientConnection": """
            Blocking POSIX socket I/O. Holds an fd and a closed flag, both behind \
            writeLock. No domain state.
            """,
        "UnixSocketServer": """
            Blocking POSIX socket I/O — a read loop cannot live on a cooperative \
            executor without starving it. Every mutable field is behind `lock`; \
            it emits an AsyncStream rather than holding callbacks. Moves bytes only.
            """,
        "Pipeline": """
            AVAudioEngine tap callback, delivered serially on one realtime thread. \
            No domain state — no model, no session. The converter is never used \
            concurrently, pendingInput never escapes the synchronous convert call, \
            and the only values read from outside are two Floats behind a lock.
            """,
        "SystemAudioTap": """
            KNOWN NON-CONFORMING, deferred deliberately — see \
            CLAUDE.md, "Not yet built". Its lock covers one field of \
            fifteen while the rest are split across two threads, and its IOProc \
            allocates, locks and writes a file. It is listed so this test tracks \
            reality; it is not an endorsement, and it must not be copied.
            """,
    ]

    func testEveryUncheckedSendableIsOnTheAllowlist() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // AirlockCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("Sources")

        var found: [String: String] = [:]  // type name → file
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            // Skip the vendored kit: it is somebody else's code and this rule is
            // about what WE write.
            guard !url.path.contains("/DynamicNotchKit/") else { continue }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }

            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                // Declarations only. Prose mentioning the attribute — including
                // this rule's own rationale — is not an exemption.
                guard trimmed.contains("@unchecked Sendable"), !trimmed.hasPrefix("//") else { continue }
                guard let name = Self.declaredTypeName(in: trimmed) else { continue }
                found[name] = url.lastPathComponent
            }
        }

        XCTAssertFalse(found.isEmpty, "the scanner found nothing — it has stopped working")

        let unexpected = found.keys.filter { Self.allowed[$0] == nil }.sorted()
        XCTAssertTrue(unexpected.isEmpty, """
            New `@unchecked Sendable` on \(unexpected.map { "\($0) (\(found[$0] ?? "?"))" }.joined(separator: ", ")).

            This is not a lint to silence by adding a line here. The criterion is in
            CLAUDE.md, Conventions: an OS boundary invoking our code on a
            thread we neither own nor can make an actor, on a type holding NO domain state,
            with every mutable field either provably owned by that thread or covered by the
            lock, and a comment saying which each field is.

            If the new type meets that, add it WITH its reason. If it does not, the type is
            the thing to change.
            """)

        let stale = Self.allowed.keys.filter { found[$0] == nil }.sorted()
        XCTAssertTrue(stale.isEmpty,
                      "allowlist entries no longer in the tree: \(stale.joined(separator: ", ")) — delete them")
    }

    /// `final class Foo: @unchecked Sendable`, `struct Foo: @unchecked Sendable, X`, etc.
    private static func declaredTypeName(in line: String) -> String? {
        for keyword in ["class ", "struct ", "enum ", "actor "] {
            guard let range = line.range(of: keyword) else { continue }
            let rest = line[range.upperBound...]
            let name = rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            if !name.isEmpty { return String(name) }
        }
        return nil
    }
}
