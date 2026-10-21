import Foundation
import AirlockCore

/// The app's half of `OutageDrill`: the flags read once from the launch
/// arguments, and the dead server put into every session that talks to
/// Airlock's own servers. With neither flag passed, every call here hands
/// back what the code had before.
enum PretendOutage {
    /// Nil unless Airlock was started with `--outage`.
    static let failure = OutageDrill.failure(in: ProcessInfo.processInfo.arguments)

    /// True only when Airlock was started with `--no-apple-intelligence`.
    static let hidesAppleIntelligence = OutageDrill.hidesAppleIntelligence(in: ProcessInfo.processInfo.arguments)

    /// Every request of a session made from `configuration` meets the dead
    /// server. Leaves it alone when there is no outage.
    static func apply(to configuration: URLSessionConfiguration) {
        guard failure != nil else { return }
        configuration.protocolClasses = [DeadServer.self] + (configuration.protocolClasses ?? [])
    }

    /// `URLSession.shared`, or during the outage a session whose every
    /// request meets the dead server.
    static var shared: URLSession { failure == nil ? .shared : deadShared }

    private static let deadShared: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        apply(to: configuration)
        return URLSession(configuration: configuration)
    }()

    /// Said once at launch, in the app's log and in meetings.log, so a
    /// pretend outage is never read as a real one afterwards.
    @MainActor
    static func announce() {
        if let failure {
            let line = OutageDrill.logLine(failure)
            Log.app.notice("\(line, privacy: .public)")
            MeetingDiagnostics.log(line)
        }
        if hidesAppleIntelligence {
            Log.app.notice("pretending Apple Intelligence is switched off")
            MeetingDiagnostics.log("pretending Apple Intelligence is switched off")
        }
    }
}

/// The server that is down, standing in front of the real one: the request
/// is never sent, and what comes back is what a dead server gives, a refused
/// connection or a 5xx with nothing useful in it. The code that asked reads
/// it as it would read the real thing.
final class DeadServer: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { PretendOutage.failure != nil }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // Only Airlock's own addresses come through here, and never a query.
        let address = (request.url?.host ?? "") + (request.url?.path ?? "")
        if case .serverError(let status)? = PretendOutage.failure, let url = request.url,
           let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                          headerFields: ["Content-Type": "text/plain"]) {
            Log.app.notice("pretend outage: \(address, privacy: .public) answered \(status)")
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("error code: \(status)".utf8))
            client?.urlProtocolDidFinishLoading(self)
        } else {
            Log.app.notice("pretend outage: \(address, privacy: .public) refused the connection")
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
        }
    }

    override func stopLoading() {}
}
