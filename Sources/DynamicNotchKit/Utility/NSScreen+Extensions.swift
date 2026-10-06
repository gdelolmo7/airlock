//
//  NSScreen+Extensions.swift
//  DynamicNotchKit
//
//  Created by Kai Azim on 2024-04-06.
//

import SwiftUI

extension NSScreen {
    static var screenWithMouse: NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        let screens = NSScreen.screens
        let screenWithMouse = (screens.first { NSMouseInRect(mouseLocation, $0.frame, false) })

        return screenWithMouse
    }

    var hasNotch: Bool {
        auxiliaryTopLeftArea?.width != nil && auxiliaryTopRightArea?.width != nil
    }

    var notchSize: NSSize? {
        guard let topLeftArea = auxiliaryTopLeftArea, let topRightArea = auxiliaryTopRightArea else {
            return nil
        }

        // agentic-notch: height from the auxiliary areas, NOT safeAreaInsets.top.
        //
        // That inset collapses to 0 whenever the menu bar is hidden on the
        // display — a full-screen app in front, or auto-hide — while the camera
        // housing is physically there either way. Reading it produced a
        // zero-height notch in exactly those moments, so the top inset this
        // drives vanished and host content was drawn under the housing.
        //
        // The auxiliary areas are the regions macOS leaves for the menu bar
        // BESIDE the cutout; their height is the cutout's height and does not
        // move with the menu bar. Measured on a 14" MacBook Pro: (0, 950, 663,
        // 32) and (848, 950, 664, 32) on a 1512x982 screen.
        let notchHeight = max(topLeftArea.height, topRightArea.height)
        let notchWidth = frame.width - topLeftArea.width - topRightArea.width
        return .init(width: notchWidth, height: notchHeight)
    }

    var notchFrame: NSRect? {
        guard let notchSize else { return nil }
        return .init(
            x: frame.midX - (notchSize.width / 2),
            y: frame.maxY - notchSize.height,
            width: notchSize.width,
            height: notchSize.height
        )
    }

    var menubarHeight: CGFloat {
        frame.maxY - visibleFrame.maxY
    }

    var notchFrameWithMenubarAsBackup: NSRect {
        if let notchFrame {
            return notchFrame
        } else {
            let arbitraryNotchWidth: CGFloat = 300
            let arbitraryNotchHeight: CGFloat = menubarHeight

            let arbitraryNotchFrame = NSRect(
                x: frame.midX - (arbitraryNotchWidth / 2),
                y: frame.maxY - arbitraryNotchHeight,
                width: arbitraryNotchWidth,
                height: arbitraryNotchHeight
            )

            return arbitraryNotchFrame
        }
    }
}
