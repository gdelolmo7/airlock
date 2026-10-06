import AppKit
import AVFAudio
import AirlockCore
import CoreGraphics
import EventKit
import SwiftUI
import os

/// Every permission Airlock reads, read at once.
///
/// **Why a page polls.** A permission changes in System Settings, outside
/// this process, and macOS posts nothing Airlock can observe when it does.
/// Re-reading on `didBecomeActive` caught the trip back, but System Settings
/// sits beside the page as often as on top of it, and a switch flipped there
/// left "Not allowed" on screen until the window was clicked. Every read here
/// is a preflight: none of them prompts, none of them sends anything, and the
/// loop lives only as long as the page showing it.
struct PermissionSnapshot: Equatable {
    var calendar: EKAuthorizationStatus
    var microphone: AVAudioApplication.recordPermission
    var inputMonitoring: Bool
    var accessibility: Bool
    var screenRecording: Bool

    static func read() -> PermissionSnapshot {
        PermissionSnapshot(calendar: EKEventStore.authorizationStatus(for: .event),
                           microphone: AVAudioApplication.shared.recordPermission,
                           inputMonitoring: CGPreflightListenEventAccess(),
                           accessibility: AXIsProcessTrusted(),
                           screenRecording: CGPreflightScreenCaptureAccess())
    }
}

extension View {
    /// Calls `changed` whenever a permission flips while this view is on
    /// screen, about a second after it does. Not on appear: the view has just
    /// read everything itself.
    func watchingPermissions(_ changed: @escaping @MainActor (PermissionSnapshot) -> Void) -> some View {
        task {
            var last = PermissionSnapshot.read()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                let now = PermissionSnapshot.read()
                if now != last {
                    last = now
                    changed(now)
                }
            }
        }
    }
}

/// "Switched on and still not allowed?" with the button that clears the
/// record (`PermissionKind`). Nothing runs until the user presses Fix and then
/// says yes to a dialog that has named what it will do.
///
/// Two shapes. Suspected — a row that reads not allowed — asks the question
/// first, because most of the time the answer is "not yet" and the Fix is
/// not for them. Known (`knownOldApproval`) — Input Monitoring on file and
/// still refused — leads with the problem as a problem card, the Fix as its
/// one button, and what to do in System Settings underneath.
struct PermissionFixRow: View {
    let kind: PermissionKind
    var knownOldApproval = false
    @State private var confirming = false
    @State private var running = false
    @State private var result: String?

    private static let log = Logger(subsystem: "com.airlock.app", category: "permissions")

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if knownOldApproval {
                ProblemCard(sentence: kind.oldApprovalSentence,
                            button: running ? "Fixing…" : "Fix",
                            action: { if !running { confirming = true } })
                Text(kind.oldApprovalSteps)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(kind.fixQuestion)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Text(kind.fixExplanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(running ? "Fixing…" : "Fix") { confirming = true }
                    .disabled(running)
            }
            if let result {
                Text(result)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .confirmationDialog("Clear Airlock's \(kind.systemName) record?", isPresented: $confirming) {
            Button(kind.asksWithADialog ? "Clear" : "Clear and Open System Settings") { Task { await fix() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(kind.asksWithADialog
                 ? "macOS forgets Airlock's earlier answer, so Allow can ask again. Nothing else changes."
                 : "Airlock's switch in \(kind.systemName) goes back to off, and nothing else changes. Then switch it on again.")
        }
    }

    private func fix() async {
        running = true
        defer { running = false }
        let bundleID = Bundle.main.bundleIdentifier ?? "com.airlock.app"
        let ok = await PermissionReset.run(kind, bundleIdentifier: bundleID)
        Self.log.notice("permission fix \(kind.service, privacy: .public): \(ok ? "cleared" : "not cleared", privacy: .public)")
        guard ok else {
            // Still opens the list: the by-hand route (remove with –, add
            // back with +) is the next thing to try, and it lives there.
            if !kind.asksWithADialog, let url = kind.settingsURL {
                result = "Nothing was changed. In the list that opened, remove Airlock with –, then add it back with +."
                NSWorkspace.shared.open(url)
            } else {
                result = "Nothing was changed."
            }
            return
        }
        result = kind.afterFix
        if !kind.asksWithADialog, let url = kind.settingsURL { NSWorkspace.shared.open(url) }
    }
}

/// Runs the reset. Off the main thread, because the administrator prompt waits
/// on a person, and the Settings window must not stop drawing while it does.
enum PermissionReset {
    static func run(_ kind: PermissionKind, bundleIdentifier: String) async -> Bool {
        let command = "/usr/bin/" + kind.resetCommand(bundleIdentifier: bundleIdentifier)
        let process = Process()
        if kind.needsAdministrator {
            // macOS's own password dialog, with a line saying why. The command
            // is built from two fixed words and a bundle identifier, so there is
            // nothing in it to quote.
            let prompt = "Airlock is clearing its \(kind.systemName) record."
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", "do shell script \"\(command)\" with prompt \"\(prompt)\" with administrator privileges"]
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            process.arguments = ["reset", kind.service, bundleIdentifier]
        }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return await withCheckedContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus == 0) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(returning: false)
            }
        }
    }
}
