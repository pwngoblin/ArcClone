import AppKit
import SwiftUI

/// When a page takes over the screen (element fullscreen), say which site it is and how to leave,
/// so a page can't silently pose as the system or another app. Drawn by ArcClone above the page;
/// the page can't cover or hide it.
@MainActor
enum FullscreenNotice {
    private static var panel: NSPanel?
    private static var hideTask: Task<Void, Never>?

    static func show(host: String, on screen: NSScreen?) {
        guard let screen = screen ?? NSScreen.main else { return }
        let content = NSHostingView(rootView: NoticeView(host: host))
        content.frame.size = content.fittingSize
        let panel = self.panel ?? {
            let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.level = .statusBar
            panel.ignoresMouseEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            return panel
        }()
        self.panel = panel
        panel.contentView = content
        let size = content.fittingSize
        panel.setFrame(NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height - 40,
                              width: size.width, height: size.height), display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.2; panel.animator().alphaValue = 1 }
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(3.5))
            guard !Task.isCancelled else { return }
            hide()
        }
    }

    static func hide() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; panel.animator().alphaValue = 0 }, completionHandler: {
            MainActor.assumeIsolated { panel.orderOut(nil) }
        })
    }

    private struct NoticeView: View {
        let host: String
        var body: some View {
            HStack(spacing: 8) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                Text("\(host) is now full screen").fontWeight(.semibold)
                Text("Press Esc to exit").foregroundStyle(.secondary)
            }
            .font(.system(size: 13))
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .environment(\.colorScheme, .dark)
        }
    }
}
