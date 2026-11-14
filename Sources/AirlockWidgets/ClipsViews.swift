import AirlockCore
import AppKit
import SwiftUI
import WidgetKit

/// The "Last copied" widget's three sizes, drawn from a snapshot, a look and
/// a way to find each copied picture, so the screenshots can draw every state.
struct ClipsView: View {
    enum Size { case small, medium, large }

    var clips: DeskClips
    var size: Size
    var look: DeskLook
    var picture: (DeskClips.Clip) -> NSImage?
    /// False only for the screenshots: an image cannot draw a link.
    var live = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !clips.isOn {
                note(DeskClipsWords.offTitle, DeskClipsWords.offLine)
            } else if clips.clips.isEmpty {
                note(DeskClipsWords.emptyTitle, DeskClipsWords.emptyLine)
            } else {
                switch size {
                case .small: small
                case .medium: rows(3).padding(.top, 8)
                case .large: rows(6).padding(.top, 10)
                }
            }
        }
        .foregroundStyle(look.fg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Sizes

    /// The newest copy, big enough to read. The whole widget copies it again
    /// (`ClipsEntryView` sets the widget's link).
    @ViewBuilder private var small: some View {
        if let clip = clips.clips.first {
            VStack(alignment: .leading, spacing: 6) {
                Group {
                    switch clip.kind {
                    case .image:
                        pictureTile(clip, corner: 10)
                    case .text where clip.isHidden:
                        hiddenBlock(clip)
                    case .file:
                        Label { Text(clip.line).lineLimit(3) } icon: { Image(systemName: "doc") }
                            .font(DeskType.text(13, weight: .medium))
                    case .text:
                        Text(clip.line)
                            .font(DeskType.text(13, weight: .regular))
                            .lineLimit(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                footer(clip)
            }
            .padding(.top, 10)
        }
    }

    private func rows(_ count: Int) -> some View {
        VStack(alignment: .leading, spacing: size == .large ? 6 : 4) {
            ForEach(Array(clips.clips.prefix(count))) { clip in
                linked(clip.copyURL) { row(clip) }
            }
            Spacer(minLength: 0)
            if size == .large {
                Text(DeskClipsWords.clickToCopy)
                    .font(DeskType.text(11, weight: .regular))
                    .foregroundStyle(look.fg3)
            }
        }
    }

    // MARK: Pieces

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.on.clipboard.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(look.accent)
                .widgetAccentable()
            Text(DeskClipsWords.title).font(DeskType.title(14)).lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    private func row(_ clip: DeskClips.Clip) -> some View {
        let side: CGFloat = size == .large ? 34 : 30
        return HStack(spacing: 9) {
            Group {
                if clip.kind == .image {
                    pictureTile(clip, corner: 7)
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 7, style: .continuous).fill(look.well)
                        Image(systemName: Self.symbol(for: clip))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(clip.isHidden ? look.accent : look.fg2)
                    }
                }
            }
            .frame(width: side, height: side)
            VStack(alignment: .leading, spacing: 1) {
                Text(clip.line)
                    .font(DeskType.text(12.5, weight: clip.isHidden ? .medium : .regular))
                    .foregroundStyle(clip.isHidden ? look.fg2 : look.fg)
                    .lineLimit(1)
                if size == .large, let app = clip.app {
                    Text(app).font(DeskType.text(10.5, weight: .regular)).foregroundStyle(look.fg3).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if clip.pinned {
                Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(look.fg3)
            }
            Text(clip.copiedAt, style: .time)
                .font(DeskType.mono(10.5))
                .foregroundStyle(look.fg3)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func hiddenBlock(_ clip: DeskClips.Clip) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "lock.fill")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(look.accent)
            Text("••••••••").font(DeskType.mono(15, weight: .medium)).foregroundStyle(look.fg2)
            Text(clip.line).font(DeskType.text(11.5, weight: .medium)).foregroundStyle(look.fg2).lineLimit(2)
        }
    }

    private func footer(_ clip: DeskClips.Clip) -> some View {
        HStack(spacing: 4) {
            if let app = clip.app {
                Text(app).lineLimit(1)
                Text("·")
            }
            Text(clip.copiedAt, style: .time).lineLimit(1)
        }
        .font(DeskType.text(10.5, weight: .medium))
        .foregroundStyle(look.fg3)
    }

    private func note(_ title: String, _ line: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Spacer(minLength: 0)
            Text(title).font(DeskType.title(size == .small ? 15 : 17))
            Text(line)
                .font(DeskType.text(12, weight: .regular))
                .foregroundStyle(look.fg2)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }

    @ViewBuilder private func pictureTile(_ clip: DeskClips.Clip, corner: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        ZStack {
            shape.fill(look.well)
            if let image = picture(clip) {
                Color.clear.overlay { Image(nsImage: image).resizable().scaledToFill() }.clipShape(shape)
            } else {
                Image(systemName: "photo").font(.system(size: 14)).foregroundStyle(look.fg2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    static func symbol(for clip: DeskClips.Clip) -> String {
        if clip.isHidden { return "lock.fill" }
        switch clip.kind {
        case .image: return "photo"
        case .file: return "doc"
        case .text: return clip.text.map { $0.hasPrefix("http://") || $0.hasPrefix("https://") } == true
            ? "link" : "text.alignleft"
        }
    }

    @ViewBuilder private func linked(_ url: URL, @ViewBuilder _ label: () -> some View) -> some View {
        if live { Link(destination: url, label: label) } else { label() }
    }
}
