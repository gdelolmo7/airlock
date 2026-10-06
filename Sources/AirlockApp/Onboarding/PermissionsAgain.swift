import AppKit
import SwiftUI
import AirlockCore

/// "Airlock needs its macOS permissions again" — shown once, at the first
/// launch after the app was renamed (`IdentityMigration.needsPermissionReview`).
///
/// It was a bare system alert that said "all four" while Settings listed six
/// and left two out by name. Now a small window of Airlock's own, built from
/// plain values so the state gallery can draw it, that names every permission
/// Settings › Permissions actually shows — read from the same list, never
/// counted by hand.
struct PermissionsAgainView: View {
    /// What Settings › Permissions lists, in its words. See `names(guideOn:)`.
    let names: [String]
    var onLater: () -> Void = {}
    var onOpenSettings: () -> Void = {}

    static let width: CGFloat = 460

    /// Every permission row Settings › Permissions shows: one per
    /// `PermissionKind` — Screen Recording only while the guide is on, as
    /// the pane does — and Automation, which is not a `PermissionKind`
    /// because macOS asks for it per terminal app.
    static func names(guideOn: Bool) -> [String] {
        PermissionKind.allCases
            .filter { $0 != .screenRecording || guideOn }
            .map(\.systemName)
            + ["Automation"]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(.tint)
                    .frame(width: 36)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Airlock needs its macOS permissions again")
                        .font(.system(size: 15, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Your settings, rules, clipboard history and connected agents all came across "
                         + "when the app was renamed. macOS permissions couldn't, because macOS ties them "
                         + "to an app's name.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Settings › \(SettingsPane.permissions.title) has a button for each one you use:")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(names, id: \.self) { name in
                            Label(name, systemImage: "circle.fill")
                                .labelStyle(BulletLabel())
                        }
                    }
                    .font(.system(size: 12.5))
                    Text("Nothing is lost while one is off — the feature that needs it just stays off until you turn it on.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            }
            .padding(20)

            HStack(spacing: 10) {
                Spacer()
                Button("Later", action: onLater)
                    .keyboardShortcut(.cancelAction)
                Button("Open Settings", action: onOpenSettings)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.regular)
            .padding(.horizontal, 20)
            .frame(height: 52)
            .background(Color.primary.opacity(0.04))
            .overlay(alignment: .top) { Divider() }
        }
        .frame(width: Self.width)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private struct BulletLabel: LabelStyle {
        func makeBody(configuration: Configuration) -> some View {
            HStack(spacing: 8) {
                configuration.icon
                    .font(.system(size: 4))
                    .foregroundStyle(.secondary)
                configuration.title
            }
        }
    }
}

/// Puts `PermissionsAgainView` on screen once. Either button, or the red
/// one, closes it; the flag is cleared before it shows, so it never returns
/// whatever the answer — the same rule the alert it replaces followed.
@MainActor
final class PermissionsAgainWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func show(guideOn: Bool, openSettings: @escaping () -> Void) {
        let view = PermissionsAgainView(
            names: PermissionsAgainView.names(guideOn: guideOn),
            onLater: { [weak self] in self?.window?.close() },
            onOpenSettings: { [weak self] in
                self?.window?.close()
                openSettings()
            })
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Airlock"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        hosting.view.layoutSubtreeIfNeeded()
        window.setContentSize(hosting.view.fittingSize)
        self.window = window
        window.centerOnNotchScreen()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // Released after the close finishes, not during it.
        Task { @MainActor [weak self] in self?.window = nil }
    }
}
