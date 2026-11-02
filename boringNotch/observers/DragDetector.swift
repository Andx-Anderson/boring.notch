//
//  DragDetector.swift
//  boringNotch
//
//  Created by Alexander on 2025-11-20.
//

import Cocoa
import UniformTypeIdentifiers

final class DragDetector {

    // MARK: - Callbacks

    typealias VoidCallback = () -> Void
    typealias PositionCallback = (_ globalPoint: CGPoint) -> Void

    var onDragEntersNotchRegion: VoidCallback?
    var onDragExitsNotchRegion: VoidCallback?
    var onDragMove: PositionCallback?
    /// Width of the closed notch as currently drawn; falls back to the hardware notch.
    var notchWidth: (() -> CGFloat)?


    private var mouseDownMonitor: Any?
    private var mouseDraggedMonitor: Any?
    private var mouseUpMonitor: Any?

    private var pasteboardChangeCount: Int = -1
    private var isDragging: Bool = false
    private var isContentDragging: Bool = false
    private var hasEnteredNotchRegion: Bool = false
    private var pendingEnter: DispatchWorkItem?
    /// Set once this drag has reached the menu bar near the notch; from then on it is kept below it.
    private var holdingOff: Bool = false

    /// How long a drag must stay over the notch before it opens. Passing over it on the way to a
    /// browser tab or the menu bar is not a request to drop there.
    static let hoverDelay: TimeInterval = 0.3


    /// Half the width of the area around the notch where drags are kept out of the menu bar -
    /// about the open shelf's width, so menu bar items further out still take drops.
    static let holdOffHalfWidth: CGFloat = openNotchSize.width / 2 + 20

    private let notchRegion: CGRect
    private let dragPasteboard = NSPasteboard(name: .drag)

    init(notchRegion: CGRect) {
        self.notchRegion = notchRegion
    }

    // MARK: - Private Helpers
    
    /// Checks if the drag pasteboard contains valid content types that can be dropped on the shelf
    private func hasValidDragContent() -> Bool {
        let validTypes: [NSPasteboard.PasteboardType] = [
            .fileURL,
            NSPasteboard.PasteboardType(UTType.url.identifier),
            .string
        ]
        return dragPasteboard.types?.contains(where: validTypes.contains) ?? false
    }

    func startMonitoring() {
        stopMonitoring()

        // Track pasteboard to detect content drag
        mouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            guard let self = self else { return }
            self.pasteboardChangeCount = self.dragPasteboard.changeCount
            self.isDragging = true
            self.isContentDragging = false
            self.hasEnteredNotchRegion = false
            self.holdingOff = false
        }

        // Track drag movement and notch region intersection
        mouseDraggedMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged]) { [weak self] event in
            guard let self = self else { return }
            guard self.isDragging else { return }

            let newContent = self.dragPasteboard.changeCount != self.pasteboardChangeCount
            
            // Detect if actual content is being dragged AND it's valid content
            if newContent && !self.isContentDragging && self.hasValidDragContent() {
                self.isContentDragging = true
            }

            // Only process position when content is being dragged
            if self.isContentDragging {
                var mouseLocation = NSEvent.mouseLocation
                // Only the notch itself opens the shelf - the black pill as it is drawn right
                // now, not the menu bar beside it. It opens at once and the drag is then kept out
                // of the menu bar (see holdOff), since it is sitting in the menu bar strip already.
                if !self.holdingOff, self.isOnNotch(mouseLocation) {
                    self.holdingOff = true
                    self.hasEnteredNotchRegion = true
                    self.onDragEntersNotchRegion?()
                }
                // Leaving the open shelf's area ends the hold: the shelf closes behind the drag and
                // the tabs under the notch must be reachable again.
                if self.holdingOff, !self.isInOpenNotchArea(mouseLocation) {
                    self.holdingOff = false
                    self.hasEnteredNotchRegion = false
                }
                if self.holdingOff, let held = self.holdOff(mouseLocation) { mouseLocation = held }
                self.onDragMove?(mouseLocation)
            }
        }

        mouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
            guard let self = self else { return }
            guard self.isDragging else { return }
            
            self.isDragging = false
            self.isContentDragging = false
            self.hasEnteredNotchRegion = false
            self.holdingOff = false
            self.cancelPendingEnter()
            self.pasteboardChangeCount = -1
        }
    }

    /// macOS 27 opens Mission Control when a file drag lingers anywhere in the menu bar strip -
    /// tested: held at 3, 12 and 25 pt from the top it opened, at 45 pt it did not, with or without
    /// this app running. The Dock's top-drag setting only covers window drags and
    /// `mcx-expose-disabled` is ignored, so there is no switch. Instead, once a drag has gone for the
    /// notch it is held just under the menu bar, which is where the shelf's drop area is anyway.
    /// Only after that: holding every drag near the notch made browser tabs under it unreachable.
    private func holdOff(_ point: CGPoint) -> CGPoint? {
        guard let screen = notchScreen(containing: point),
              abs(point.x - notchRegion.midX) <= Self.holdOffHalfWidth,
              let primaryHeight = NSScreen.screens.first?.frame.height
        else { return nil }
        let limit = Self.holdOffLine(on: screen)
        guard point.y > limit else { return nil }
        let held = CGPoint(x: point.x, y: limit)
        // Cocoa's origin is bottom-left of the primary screen; Quartz's is top-left.
        CGWarpMouseCursorPosition(CGPoint(x: held.x, y: primaryHeight - held.y))
        CGAssociateMouseAndMouseCursorPosition(1)
        return held
    }

    /// On the black pill: its current drawn width (wider while music plays), top strip only.
    private func isOnNotch(_ point: CGPoint) -> Bool {
        guard let screen = notchScreen(containing: point) else { return false }
        let width = notchWidth?() ?? notchRegion.width
        let height = max(Self.menuBarHeight(on: screen), notchRegion.height)
        return abs(point.x - notchRegion.midX) <= width / 2
            && point.y > screen.frame.maxY - height
    }

    /// Roughly where the open shelf is drawn: open-notch size plus a little slack.
    private func isInOpenNotchArea(_ point: CGPoint) -> Bool {
        guard let screen = notchScreen(containing: point) else { return false }
        return abs(point.x - notchRegion.midX) <= Self.holdOffHalfWidth
            && point.y >= screen.frame.maxY - (openNotchSize.height + 20)
    }

    /// The screen under `point`, if it is the one this detector's notch is on.
    private func notchScreen(containing point: CGPoint) -> NSScreen? {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }),
              screen.frame.contains(CGPoint(x: notchRegion.midX, y: notchRegion.midY)) else { return nil }
        return screen
    }

    static func menuBarHeight(on screen: NSScreen) -> CGFloat {
        max(screen.safeAreaInsets.top, screen.frame.maxY - screen.visibleFrame.maxY, 24)
    }

    /// Highest y (Cocoa) a content drag may reach: just below the menu bar.
    static func holdOffLine(on screen: NSScreen) -> CGFloat {
        screen.frame.maxY - menuBarHeight(on: screen) - Self.holdOffClearance
    }

    /// Gap kept under the menu bar. The cursor is pulled back only after an event has moved it,
    /// so one push up must not be able to reach the menu bar from the line: a 3 pt gap still
    /// opened Mission Control when pushing 8 pt per event, 16 pt failed at 25 pt pushes.
    static let holdOffClearance: CGFloat = 30

    private func cancelPendingEnter() {
        pendingEnter?.cancel()
        pendingEnter = nil
    }

    func stopMonitoring() {
        [mouseDownMonitor, mouseDraggedMonitor, mouseUpMonitor].forEach { monitor in
            if let monitor = monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
        mouseDownMonitor = nil
        mouseDraggedMonitor = nil
        mouseUpMonitor = nil
        isDragging = false
        isContentDragging = false
        hasEnteredNotchRegion = false
        holdingOff = false
        cancelPendingEnter()
    }

    deinit {
        stopMonitoring()
    }
}
