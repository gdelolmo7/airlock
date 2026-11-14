import AirlockCore
import Foundation
import WidgetKit

/// Keeps the "AI agents" desktop widget current: the sessions the notch
/// shows, the most urgent first, and whether Agents is switched on.
///
/// Built by `DeskAgents.make`, which never writes what an agent asked for and
/// leaves out a title or a line that looks secret. Watches the session state
/// through Observation; a burst of hook events becomes one write, and the
/// widget is asked to redraw only when the snapshot changed, so an agent
/// working away does not redraw the desk at every tool call it makes.
///
/// Like the other desktop publishers, nothing on a build with no App Group.
@MainActor
final class DeskAgentsPublisher {
    private let model: AppModel
    private let agents: AgentsWidgetModel
    private let shared: URL
    private var pending: Task<Void, Never>?
    private var last: DeskAgents?
    private var surfaceWatch: (any NSObjectProtocol)?
    private var watching = false
    var surface: @MainActor () -> DeskSurface = { .black }

    init?(model: AppModel, agents: AgentsWidgetModel, bundle: Bundle = .main) {
        guard let group = bundle.object(forInfoDictionaryKey: DeskShelf.infoKey) as? String, !group.isEmpty,
              let shared = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
        else { return nil }
        self.model = model
        self.agents = agents
        self.shared = shared
    }

    func start() {
        watching = true
        surfaceWatch = NotificationCenter.default.addObserver(
            forName: .notchSurfaceDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        observe()
        refresh()
    }

    private func observe() {
        guard watching else { return }
        withObservationTracking {
            _ = model.state
            _ = agents.isEnabled
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.refresh()
                self?.observe()
            }
        }
    }

    func refresh() {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            self.publish(DeskAgents.make(self.model.state, isOn: self.agents.isEnabled, surface: self.surface()))
        }
    }

    private func publish(_ desk: DeskAgents) {
        guard desk != last else { return }
        last = desk
        let url = shared.appendingPathComponent(DeskAgents.snapshotName)
        guard let data = try? DeskShelf.encoder().encode(desk) else { return }
        if (try? Data(contentsOf: url)) != data { try? data.write(to: url, options: .atomic) }
        WidgetCenter.shared.reloadTimelines(ofKind: DeskAgents.widgetKind)
    }

    func stop() {
        watching = false
        pending?.cancel()
        if let surfaceWatch { NotificationCenter.default.removeObserver(surfaceWatch) }
        surfaceWatch = nil
    }
}
