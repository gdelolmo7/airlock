import Foundation
import SwiftUI
import WidgetKit

/// Airlock's desktop widgets. Built by SwiftPM, wrapped into
/// `Airlock.app/Contents/PlugIns/AirlockWidgets.appex` by the packaging
/// script; there is no Xcode project.
struct AirlockWidgetBundle: WidgetBundle {
    var body: some Widget {
        CallTodosWidget()
        NextCallWidget()
        ShelfWidget()
        ClipsWidget()
        AgentsWidget()
    }
}

// `--desk-shots <folder>` draws every size and look to PNGs for review, from
// made-up to-dos, and quits. The system never starts the widget with it.
// Debug builds only (`swift run AirlockWidgets --desk-shots …`): a release
// build enters at `NSExtensionMain` (Package.swift), which refuses a shell.
if let flag = CommandLine.arguments.firstIndex(of: "--desk-shots"),
   CommandLine.arguments.count > flag + 1 {
    let folder = URL(fileURLWithPath: CommandLine.arguments[flag + 1], isDirectory: true)
    MainActor.assumeIsolated { DeskShots.render(into: folder) }
    exit(0)
}
AirlockWidgetBundle.main()
