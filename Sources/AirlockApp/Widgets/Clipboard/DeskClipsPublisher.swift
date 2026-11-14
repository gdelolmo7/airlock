import AirlockCore
import AppKit
import Foundation
import ImageIO
import WidgetKit

/// Keeps the "Last copied" desktop widget current: the newest copies the
/// plan shows, a small picture of each copied image, and whether clipboard
/// history is switched on.
///
/// Built by `DeskClips.make`, which writes text that looks secret as its
/// length only. Watches the clipboard model through Observation; a burst of
/// copies becomes one write, and the widget is asked to redraw only when the
/// snapshot changed. Pictures are made once per copy and removed once no
/// shown copy uses them.
///
/// Like the other desktop publishers, nothing on a build with no App Group.
@MainActor
final class DeskClipsPublisher {
    private let clipboard: ClipboardWidgetModel
    private let shared: URL
    private var pending: Task<Void, Never>?
    private var last: DeskClips?
    private var surfaceWatch: (any NSObjectProtocol)?
    private var watching = false
    var surface: @MainActor () -> DeskSurface = { .black }

    init?(clipboard: ClipboardWidgetModel, bundle: Bundle = .main) {
        guard let group = bundle.object(forInfoDictionaryKey: DeskShelf.infoKey) as? String, !group.isEmpty,
              let shared = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
        else { return nil }
        self.clipboard = clipboard
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
            _ = clipboard.history
            _ = clipboard.isEnabled
            _ = clipboard.planShows
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
            let thumbs = self.shared.appendingPathComponent(DeskClips.thumbsFolder, isDirectory: true)
            try? FileManager.default.createDirectory(at: thumbs, withIntermediateDirectories: true)
            let snapshot = DeskClips.make(
                self.clipboard.history.items, planShows: self.clipboard.planShows,
                isOn: self.clipboard.isEnabled, surface: self.surface()
            ) { item in
                guard item.isImage, let source = self.clipboard.imageURL(for: item) else { return nil }
                let key = DeskClips.clip(for: item).thumbKey
                let target = thumbs.appendingPathComponent(key)
                if FileManager.default.fileExists(atPath: target.path) { return key }
                guard let png = Self.smallPicture(of: source) else { return nil }
                try? png.write(to: target, options: .atomic)
                return key
            }
            self.sweep(thumbs, keeping: snapshot)
            self.publish(snapshot)
        }
    }

    /// The copied image, no wider or taller than 360 pixels.
    private static func smallPicture(of url: URL) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 360,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    private func sweep(_ thumbs: URL, keeping snapshot: DeskClips) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: thumbs.path)) ?? []
        for name in snapshot.staleThumbs(among: names) {
            try? FileManager.default.removeItem(at: thumbs.appendingPathComponent(name))
        }
    }

    private func publish(_ clips: DeskClips) {
        guard clips != last else { return }
        last = clips
        let url = shared.appendingPathComponent(DeskClips.snapshotName)
        guard let data = try? DeskShelf.encoder().encode(clips) else { return }
        if (try? Data(contentsOf: url)) != data { try? data.write(to: url, options: .atomic) }
        WidgetCenter.shared.reloadTimelines(ofKind: DeskClips.widgetKind)
    }

    func stop() {
        watching = false
        pending?.cancel()
        if let surfaceWatch { NotificationCenter.default.removeObserver(surfaceWatch) }
        surfaceWatch = nil
    }
}
