import AppKit
import Observation
import AirlockCore
import os

/// The app's half of `UsageConnection`: what the settings file says, and the
/// two moments it is asked to change — launch, and the switch being flipped.
///
/// It holds the state rather than computing it in a view, for the reason
/// `AgentsWidgetModel` holds its hook statuses: reading it touches the
/// filesystem, and a SwiftUI body is not where a file gets read.
@MainActor
@Observable
final class UsageConnectionModel {
    private(set) var state: UsageConnection.State = .hooksMissing

    /// Why the last attempt failed, or nil. On the pane that offered the
    /// button, because a button that silently does nothing is worse than none.
    private(set) var failure: String?

    private nonisolated static let log = Logger(subsystem: "com.airlock.app", category: "usage")
    @ObservationIgnored private let connection: UsageConnection
    @ObservationIgnored private let bridgeBinaryPath: @MainActor () -> String?

    init(connection: UsageConnection = UsageConnection(),
         bridgeBinaryPath: @escaping @MainActor () -> String? = UsageConnectionModel.stagedHook) {
        self.connection = connection
        self.bridgeBinaryPath = bridgeBinaryPath
        state = connection.state()
    }

    func refresh() { state = connection.state() }

    /// Launch, and every flip of the switch, go through here.
    @discardableResult
    func sync(wantsUsage: Bool) -> UsageConnection.Change {
        let change = connection.sync(wantsUsage: wantsUsage, bridgeBinaryPath: bridgeBinaryPath())
        if case let .failed(why) = change {
            // The system's words are for the log; the pane gets ours.
            Self.log.error("usage connect failed: \(why, privacy: .private)")
            failure = "Claude usage couldn't be connected. Try again in a moment."
        } else {
            failure = nil
        }
        refresh()
        return change
    }

    /// The button in Settings, for somebody who does not want to wait for the
    /// next launch to get their figures back.
    func connect() { sync(wantsUsage: true) }

    /// The binary Claude should run: the one already staged for the hooks, or a
    /// fresh copy of the one inside this bundle. Same path the hooks use, so
    /// the two cannot drift onto different binaries.
    private static func stagedHook() -> String? {
        let staged = HookBinaryStager.defaultStagedURL()
        if FileManager.default.isExecutableFile(atPath: staged.path) { return staged.path }
        guard let source = HookBinaryStager.locateSourceHook(near: Bundle.main.executableURL),
              let copied = try? HookBinaryStager.stage(from: source) else { return nil }
        return copied.path
    }
}
