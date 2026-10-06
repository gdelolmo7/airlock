//
//  NotchView.swift
//  DynamicNotchKit
//
//  Created by Kai Azim on 2023-08-24.
//

import SwiftUI

struct NotchView<Expanded, CompactLeading, CompactTrailing>: View where Expanded: View, CompactLeading: View, CompactTrailing: View {
    @ObservedObject private var dynamicNotch: DynamicNotch<Expanded, CompactLeading, CompactTrailing>
    @State private var compactLeadingWidth: CGFloat = 0
    @State private var compactTrailingWidth: CGFloat = 0
    private let safeAreaInset: CGFloat = 15

    init(dynamicNotch: DynamicNotch<Expanded, CompactLeading, CompactTrailing>) {
        self.dynamicNotch = dynamicNotch
    }

    private var expandedNotchCornerRadii: (top: CGFloat, bottom: CGFloat) {
        if case let .notch(topCornerRadius, bottomCornerRadius) = dynamicNotch.style {
            (top: topCornerRadius, bottom: bottomCornerRadius)
        } else {
            (top: 15, bottom: 20)
        }
    }

    private var compactNotchCornerRadii: (top: CGFloat, bottom: CGFloat) {
        (top: 6, bottom: 14)
    }

    private var minWidth: CGFloat {
        dynamicNotch.notchSize.width + (topCornerRadius * 2)
    }

    private var topCornerRadius: CGFloat {
        dynamicNotch.state == .expanded ? expandedNotchCornerRadii.top : compactNotchCornerRadii.top
    }

    private var bottomCornerRadius: CGFloat {
        dynamicNotch.state == .expanded ? expandedNotchCornerRadii.bottom : compactNotchCornerRadii.bottom
    }

    private var xOffset: CGFloat {
        if dynamicNotch.state != .compact {
            0
        } else {
            compactXOffset
        }
    }

    private var compactXOffset: CGFloat {
        (compactTrailingWidth - compactLeadingWidth) / 2
    }

    var body: some View {
        notchContent()
            .background {
                // agentic-notch: the ground is the host's choice now. Upstream
                // hardcoded opaque black here, which meant anything translucent
                // drawn INSIDE the notch had only that black to sample — real
                // glass came out as a flat grey slab. Defaults to black, so
                // upstream behaviour is unchanged unless a host opts out.
                Rectangle()
                    .foregroundStyle(dynamicNotch.backgroundStyle)
                    .padding(-50) // The opening/closing animation can overshoot, so this makes sure that it's still black
            }
            .mask {
                NotchShape(
                    topCornerRadius: topCornerRadius,
                    bottomCornerRadius: bottomCornerRadius
                )
                .padding(.horizontal, 0.5)
                .frame(
                    width: dynamicNotch.state != .hidden ? nil : minWidth,
                    height: dynamicNotch.state != .hidden ? nil : dynamicNotch.notchSize.height
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .offset(x: xOffset)
            .animation(.smooth, value: [compactLeadingWidth, compactTrailingWidth])
    }

    private func notchContent() -> some View {
        ZStack {
            compactContent()
                .fixedSize()
                .offset(x: dynamicNotch.state == .compact ? 0 : compactXOffset)
                .frame(
                    width: dynamicNotch.state == .compact ? nil : dynamicNotch.notchSize.width,
                    height: (dynamicNotch.state == .compact && dynamicNotch.isHovering) ? dynamicNotch.menubarHeight : dynamicNotch.notchSize.height
                )

            expandedContent()
                .fixedSize()
                .frame(
                    maxWidth: dynamicNotch.state == .expanded ? nil : 0,
                    maxHeight: dynamicNotch.state == .expanded ? nil : 0
                )
                .offset(x: dynamicNotch.state == .compact ? -compactXOffset : 0)
        }
        .padding(.horizontal, topCornerRadius)
        .fixedSize()
        .frame(minWidth: minWidth, minHeight: dynamicNotch.notchSize.height)
        .onHover(perform: dynamicNotch.updateHoverState)
    }

    func compactContent() -> some View {
        HStack(spacing: 0) {
            if dynamicNotch.state == .compact, !dynamicNotch.disableCompactLeading {
                dynamicNotch.compactLeadingContent
                    .environment(\.notchSection, .compactLeading)
                    .safeAreaInset(edge: .leading, spacing: 0) { Color.clear.frame(width: 8) }
                    .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: 4) }
                    .safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: 8) }
                    .onGeometryChange(for: CGFloat.self, of: \.size.width) {
                        compactLeadingWidth = $0
                        dynamicNotch.onCompactGeometry?(compactLeadingWidth, compactTrailingWidth)
                    }
                    // LOCAL MODIFICATION. `.identity`, EXPLICITLY — and the
                    // reason is measured rather than aesthetic.
                    //
                    // A transition here can be INTERRUPTED and leave the view
                    // stranded: laid out, reporting its real width to
                    // `onGeometryChange`, and drawn at opacity 0. That is
                    // exactly the state every other measurement pointed at and
                    // could not name — window visible with alpha 1.00 at the
                    // right frame on the right screen, kit in `.compact`, slots
                    // holding real content, shoulders at 33.0 and 23.5, and
                    // nothing on screen.
                    //
                    // It strands when the shoulder's CONTENT is live during the
                    // conversion that is inserting it — a playing track puts a
                    // 20fps animated wave and an async-loading artwork in these
                    // slots — which is why spoken MEDIA commands did it: a
                    // keyboard media key changes content with no conversion,
                    // and "go to Chrome" converts onto a static lamp and count.
                    //
                    // It was `.blur + .scale(x: 0) + .opacity`, then `.opacity`
                    // alone; both strand, because the fault is the interruption
                    // and not the effect. DELETING the modifier does not help —
                    // that reverts to SwiftUI's DEFAULT insertion transition,
                    // which is `.opacity` again, and it strands identically.
                    // The bug shipped once behind exactly that deletion.
                    // `.identity` is the only spelling of "none": no wrapper,
                    // nothing to interrupt. The conversion still reads as
                    // motion because the notch shape's mask and frame animate
                    // over the content either way.
                    .transition(.identity)
            }

            Spacer()
                .frame(width: dynamicNotch.notchSize.width)

            if dynamicNotch.state == .compact, !dynamicNotch.disableCompactTrailing {
                dynamicNotch.compactTrailingContent
                    .environment(\.notchSection, .compactTrailing)
                    .safeAreaInset(edge: .trailing, spacing: 0) { Color.clear.frame(width: 8) }
                    .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: 4) }
                    .safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: 8) }
                    .onGeometryChange(for: CGFloat.self, of: \.size.width) {
                        compactTrailingWidth = $0
                        dynamicNotch.onCompactGeometry?(compactLeadingWidth, compactTrailingWidth)
                    }
                    // `.identity`, explicitly — see the leading shoulder above.
                    .transition(.identity)
            }
        }
        .frame(height: dynamicNotch.notchSize.height)
        .onChange(of: dynamicNotch.disableCompactLeading) { _ in
            if dynamicNotch.disableCompactLeading {
                compactLeadingWidth = 0
            }
        }
        .onChange(of: dynamicNotch.disableCompactTrailing) { _ in
            if dynamicNotch.disableCompactTrailing {
                compactTrailingWidth = 0
            }
        }
    }

    func expandedContent() -> some View {
        HStack(spacing: 0) {
            if dynamicNotch.state == .expanded {
                dynamicNotch.expandedContent
                    .transition(.blur(intensity: 10).combined(with: .scale(y: 0.6, anchor: .top)).combined(with: .opacity))
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: dynamicNotch.notchSize.height) }
        .safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: safeAreaInset) }
        .safeAreaInset(edge: .leading, spacing: 0) { Color.clear.frame(width: safeAreaInset) }
        .safeAreaInset(edge: .trailing, spacing: 0) { Color.clear.frame(width: safeAreaInset) }
        .frame(minWidth: dynamicNotch.notchSize.width)
    }
}

