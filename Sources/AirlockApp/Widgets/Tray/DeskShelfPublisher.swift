import AirlockCore
import AppKit
import Foundation
import QuickLookThumbnailing
import WidgetKit

/// Keeps the "Shelf" desktop widget current: the newest files on the Shelf,
/// a small picture of each, and whether the Shelf is switched on.
///
/// Watches the shelf model through Observation rather than its `onChange`,
/// which the notch already owns. A burst of changes (a drop of ten files)
/// becomes one write, and the widget is asked to redraw only when the
/// snapshot changed. Pictures are made once per version of a file and kept
/// under the file's `thumbKey`; ones no file uses any more are removed.
///
/// Like the other desktop publishers, nothing on a build with no App Group.
@MainActor
final class DeskShelfPublisher {
    private let tray: TrayModel
    private let shelf: URL
    private var pending: Task<Void, Never>?
    private var last: DeskShelfFiles?
    private var surfaceWatch: (any NSObjectProtocol)?
    private var watching = false
    var surface: @MainActor () -> DeskSurface = { .black }

    init?(tray: TrayModel, bundle: Bundle = .main) {
        guard let group = bundle.object(forInfoDictionaryKey: DeskShelf.infoKey) as? String, !group.isEmpty,
              let shelf = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
        else { return nil }
        self.tray = tray
        self.shelf = shelf
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

    /// Observation fires once per registration, so each change registers
    /// again; `watching` stops the chain once `stop()` has run.
    private func observe() {
        guard watching else { return }
        withObservationTracking {
            _ = tray.items
            _ = tray.isEnabled
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
            let items = self.tray.items
            let isOn = self.tray.isEnabled
            let thumbs = self.shelf.appendingPathComponent(DeskShelfFiles.thumbsFolder, isDirectory: true)
            try? FileManager.default.createDirectory(at: thumbs, withIntermediateDirectories: true)

            var files: [DeskShelfFiles.File] = []
            let newest = isOn ? Array(items.prefix(DeskShelfFiles.limit)) : []
            for item in newest {
                guard !Task.isCancelled else { return }
                var file = DeskShelfFiles.File(name: item.name, size: item.size, modified: item.modified,
                                               isFolder: item.isDirectory)
                let key = file.thumbKey
                let target = thumbs.appendingPathComponent(key)
                let iconMark = thumbs.appendingPathComponent(key + ".icon")
                if FileManager.default.fileExists(atPath: target.path) {
                    file.thumb = key
                    file.thumbIsIcon = FileManager.default.fileExists(atPath: iconMark.path)
                } else if let (png, isIcon) = await Self.picture(of: item) {
                    try? png.write(to: target, options: .atomic)
                    if isIcon { try? Data().write(to: iconMark) }
                    file.thumb = key
                    file.thumbIsIcon = isIcon
                }
                files.append(file)
            }
            // The rest of the Shelf counts toward the total but gets no picture.
            let rest = isOn ? items.dropFirst(DeskShelfFiles.limit).map {
                DeskShelfFiles.File(name: $0.name, size: $0.size, modified: $0.modified, isFolder: $0.isDirectory)
            } : []
            let snapshot = DeskShelfFiles.make(files + rest, isOn: isOn, surface: self.surface())
            self.sweep(thumbs, keeping: snapshot)
            self.publish(snapshot)
        }
    }

    /// A preview when QuickLook can make one, the file's own icon otherwise;
    /// folders always get the icon, since a preview of one is a blank page.
    private static func picture(of item: TrayItem) async -> (Data, Bool)? {
        if !item.isDirectory {
            let request = QLThumbnailGenerator.Request(
                fileAt: item.url, size: CGSize(width: 120, height: 120),
                scale: 2, representationTypes: .thumbnail)
            if let made = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request),
               let png = png(made.cgImage) {
                return (png, false)
            }
        }
        let icon = NSWorkspace.shared.icon(forFile: item.url.path)
        var rect = CGRect(x: 0, y: 0, width: 128, height: 128)
        guard let image = icon.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              let png = png(image) else { return nil }
        return (png, true)
    }

    private static func png(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    private func sweep(_ thumbs: URL, keeping snapshot: DeskShelfFiles) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: thumbs.path)) ?? []
        let stale = snapshot.staleThumbs(among: names)
        let kept = Set(snapshot.files.compactMap(\.thumb))
        for name in stale { try? FileManager.default.removeItem(at: thumbs.appendingPathComponent(name)) }
        for name in names where name.hasSuffix(".png.icon") && !kept.contains(String(name.dropLast(5))) {
            try? FileManager.default.removeItem(at: thumbs.appendingPathComponent(name))
        }
    }

    private func publish(_ files: DeskShelfFiles) {
        guard files != last else { return }
        last = files
        let url = shelf.appendingPathComponent(DeskShelfFiles.snapshotName)
        guard let data = try? DeskShelf.encoder().encode(files) else { return }
        if (try? Data(contentsOf: url)) != data { try? data.write(to: url, options: .atomic) }
        WidgetCenter.shared.reloadTimelines(ofKind: DeskShelfFiles.widgetKind)
    }

    func stop() {
        watching = false
        pending?.cancel()
        if let surfaceWatch { NotificationCenter.default.removeObserver(surfaceWatch) }
        surfaceWatch = nil
    }
}
