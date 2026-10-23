import AppKit
import SwiftUI

/// User-chosen look: accent color, sidebar tint and strength, a paper-like grain, and the app's
/// light/dark appearance. Stored in UserDefaults so every window updates live via @AppStorage.
enum AppearanceStyle {
    enum Key {
        static let accent = "AppearanceAccent"
        static let sidebarTint = "AppearanceSidebarTint"
        static let tintStrength = "AppearanceTintStrength"
        static let grain = "AppearanceGrain"
        static let appAppearance = "AppearanceMode"
    }

    static let defaultAccent = "#5B4CF5"
    static let presets = ["#5B4CF5", "#0A84FF", "#30B0C7", "#34C759", "#FF9F0A", "#FF375F", "#BF5AF2", "#8E8E93"]

    enum Mode: String, CaseIterable {
        case system, light, dark
        var title: String { rawValue.capitalized }
    }

    /// Applies the app-wide light/dark choice (AppKit and SwiftUI follow `NSApp.appearance`).
    @MainActor
    static func applyAppAppearance() {
        let mode = UserDefaults.standard.string(forKey: Key.appAppearance).flatMap(Mode.init(rawValue:)) ?? .system
        switch mode {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

extension Color {
    init(hex: String) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")).prefix(6)
        let value = UInt32(digits, radix: 16) ?? 0x5B4CF5
        self.init(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }

    var hexString: String {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .systemPurple
        let byte = { (v: CGFloat) in Int((min(1, max(0, v)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(c.redComponent), byte(c.greenComponent), byte(c.blueComponent))
    }
}

/// Reads the accent color for SwiftUI views.
struct AccentTint: ViewModifier {
    @AppStorage(AppearanceStyle.Key.accent) private var accent = AppearanceStyle.defaultAccent
    func body(content: Content) -> some View { content.tint(Color(hex: accent)) }
}

extension View {
    func appAccent() -> some View { modifier(AccentTint()) }
}

/// Tint and grain drawn over the sidebar's system vibrancy.
struct SidebarBackground: View {
    @AppStorage(AppearanceStyle.Key.sidebarTint) private var tint = AppearanceStyle.defaultAccent
    @AppStorage(AppearanceStyle.Key.tintStrength) private var strength = 0.12
    @AppStorage(AppearanceStyle.Key.grain) private var grain = 0.0

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: tint).opacity(strength), Color(hex: tint).opacity(strength * 0.55)],
                           startPoint: .top, endPoint: .bottom)
            if grain > 0.001 {
                Image(nsImage: GrainTexture.image)
                    .resizable(resizingMode: .tile)
                    .blendMode(.overlay)
                    .opacity(grain)
            }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }
}

/// A tileable monochrome noise tile, generated once, for the "paper" grain effect.
enum GrainTexture {
    @MainActor static let image: NSImage = {
        let size = 128
        var generator = SystemRandomNumberGenerator()
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                   samplesPerPixel: 1, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceWhite,
                                   bytesPerRow: size, bitsPerPixel: 8)!
        if let pixels = rep.bitmapData {
            for i in 0..<(size * size) { pixels[i] = UInt8.random(in: 70...185, using: &generator) }
        }
        let image = NSImage(size: NSSize(width: size, height: size))
        image.addRepresentation(rep)
        return image
    }()
}
