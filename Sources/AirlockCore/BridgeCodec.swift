import Foundation

/// Newline-delimited JSON framing for the bridge socket.
///
/// A hard per-line cap closes the memory-DoS hole the reference left open
/// (an unbounded buffer that grows until a newline arrives).
public enum BridgeCodec {
    /// Maximum bytes for a single framed message (1 MiB). A peer that streams
    /// past this without a newline is dropped.
    public static let maxLineBytes = 1 << 20

    public enum CodecError: Error, Sendable {
        case lineTooLong
        case notFound
    }

    private static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .millisecondsSince1970
        return e
    }

    private static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .millisecondsSince1970
        return d
    }

    /// Encode a value to a single `\n`-terminated line.
    public static func encodeLine<T: Encodable>(_ value: T) throws -> Data {
        var data = try makeEncoder().encode(value)
        data.append(0x0A)
        return data
    }

    public static func decode<T: Decodable>(_ type: T.Type, from line: Data) throws -> T {
        try makeDecoder().decode(type, from: line)
    }

    /// Split an accumulating buffer into complete lines, returning the decoded
    /// values and the unconsumed remainder. Throws if any pending line exceeds
    /// `maxLineBytes`.
    public static func drainLines<T: Decodable>(
        _ type: T.Type,
        from buffer: inout Data
    ) throws -> [T] {
        var out: [T] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            if line.isEmpty { continue }
            if line.count > maxLineBytes { throw CodecError.lineTooLong }
            out.append(try decode(type, from: Data(line)))
        }
        if buffer.count > maxLineBytes { throw CodecError.lineTooLong }
        return out
    }
}
