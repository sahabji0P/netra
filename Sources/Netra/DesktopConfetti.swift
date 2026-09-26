import AppKit
import os
import SwiftUI

/// Presents a full-screen confetti burst across every display the moment a
/// limit resets. The overlay windows are borderless, transparent,
/// click-through, non-activating, and float above other apps (including
/// full-screen spaces), so the celebration never steals focus or blocks work.
@MainActor
final class DesktopConfetti {
    private var windows: [NSWindow] = []
    private var dismissTask: Task<Void, Never>?
    private let log = Logger(subsystem: "com.sahabji0P.netra", category: "confetti")

    /// Duration the overlay stays up before it tears itself down.
    private let lifetime: Duration = .seconds(3)

    func play(title: String) {
        dismiss()
        log.info("desktop confetti: \(title, privacy: .public) across \(NSScreen.screens.count) screen(s)")
        let mainScreen = NSScreen.main
        for screen in NSScreen.screens {
            let window = overlayWindow(on: screen, title: screen == mainScreen ? title : nil)
            windows.append(window)
        }
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: self?.lifetime ?? .seconds(3))
            self?.dismiss()
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
    }

    private func overlayWindow(on screen: NSScreen, title: String?) -> NSWindow {
        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        // Above ordinary windows and full-screen spaces, but it never becomes
        // key, so focus and the active app are untouched.
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.contentView = NSHostingView(rootView: DesktopConfettiView(title: title))
        window.setFrame(screen.frame, display: true)
        window.orderFrontRegardless()
        return window
    }
}

/// The full-screen confetti plus a brief centered banner naming what reset.
private struct DesktopConfettiView: View {
    var title: String?

    @State private var trigger = 0
    @State private var showBanner = false

    var body: some View {
        ZStack {
            ConfettiOverlay(trigger: trigger)
            if let title, showBanner {
                VStack(spacing: 6) {
                    Text("🎉")
                        .font(.system(size: 44))
                    Text(title)
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                    Text("fresh capacity")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 20)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(.separator.opacity(0.5), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.18), radius: 22, y: 8)
                .transition(.scale(scale: 0.92).combined(with: .opacity))
                .offset(y: -40)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .onAppear {
            trigger += 1
            withAnimation(.spring(response: 0.45, dampingFraction: 0.72)) { showBanner = true }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.9))
                withAnimation(.easeOut(duration: 0.5)) { showBanner = false }
            }
        }
    }
}
