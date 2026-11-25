import SwiftUI
#if os(macOS)
import AppKit
#endif

enum AppearanceTheme: String, CaseIterable, Identifiable {
    case classic
    case glass = "frosted"

    static let storageKey = "Pomodoro.appearance"
    var id: Self { self }

    var title: String {
        switch self {
        case .classic: "Classic"
        case .glass: "Glass"
        }
    }
}

extension EnvironmentValues {
    @Entry var usesGlassAppearance = false
}

enum Theme {
    static let ink = color(0x262120)
    static let muted = color(0x625752)
    static let subtle = color(0x766963)
    static let accent = color(0xEF4136)
    static let action = color(0xCF3029)
    static let accentDark = color(0xAC2722)
    static let accentSoft = color(0xFFE9E4)
    static let line = color(0xF0E4DE)
    static let card = Color.white
    static let track = color(0xF4E8E4)
    static let surface = color(0xFFFCFA)
    static let sidebar = color(0xFFF5F0)
    static let timerSurface = color(0xFFF8F5)
    static let leaf = color(0x247443)
    static let tomatoHighlight = color(0xFF5948)
    static let tomatoBase = color(0xE92824)
    static let glassBlue = color(0x9CBCE7)
    static let glassEdge = color(0x667C99)
    private static let glassHighlight = color(0xEEF6FF)

    static let glassRim = LinearGradient(
        colors: [.white, glassHighlight.opacity(0.74), glassEdge.opacity(0.45)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    private static func color(_ hex: UInt32) -> Color {
        Color(
            red: Double((hex >> 16) & 255) / 255,
            green: Double((hex >> 8) & 255) / 255,
            blue: Double(hex & 255) / 255
        )
    }
}

struct AppearanceBackdrop: View {
    let glassEnabled: Bool
    var blendsWithDesktop = false

    var body: some View {
        ZStack {
#if os(macOS)
            if blendsWithDesktop {
                MacWindowBackdrop(glassEnabled: glassEnabled)
            }
#endif
            if glassEnabled {
                Theme.surface.opacity(blendsWithDesktop ? 0.29 : 1)
                RadialGradient(colors: [Theme.glassBlue.opacity(blendsWithDesktop ? 0.34 : 0.45), .clear],
                               center: UnitPoint(x: 0.32, y: 0.12), startRadius: 12, endRadius: 430)
                RadialGradient(colors: [.white.opacity(0.24), .clear],
                               center: .bottomTrailing, startRadius: 8, endRadius: 320)
            } else {
                Theme.surface
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

#if os(macOS)
private struct MacWindowBackdrop: NSViewRepresentable {
    let glassEnabled: Bool

    func makeNSView(context: Context) -> WindowMaterialView {
        let view = WindowMaterialView()
        view.material = .sidebar
        view.appearance = NSAppearance(named: .aqua)
        view.blendingMode = .behindWindow
        view.state = .active
        view.alphaValue = 0.62
        view.setGlassEnabled(glassEnabled)
        return view
    }

    func updateNSView(_ view: WindowMaterialView, context: Context) {
        view.setGlassEnabled(glassEnabled)
    }
}

private final class WindowMaterialView: NSVisualEffectView {
    private var glassEnabled = false
    private var originalBackground: NSColor?
    private var originallyOpaque = true

    func setGlassEnabled(_ enabled: Bool) {
        guard enabled != glassEnabled else { return }
        glassEnabled = enabled
        applyAppearance()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if let window, window !== newWindow, let originalBackground {
            window.backgroundColor = originalBackground
            window.isOpaque = originallyOpaque
            self.originalBackground = nil
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window, originalBackground == nil {
            originalBackground = window.backgroundColor ?? .windowBackgroundColor
            originallyOpaque = window.isOpaque
        }
        applyAppearance()
    }

    private func applyAppearance() {
        isHidden = !glassEnabled
        guard let window, let originalBackground else { return }
        window.isOpaque = glassEnabled ? false : originallyOpaque
        window.backgroundColor = glassEnabled ? .clear : originalBackground
        window.invalidateShadow()
    }
}
#endif

struct GlassLens<Outline: InsettableShape>: View {
    let outline: Outline

    var body: some View {
        Group {
            if #available(macOS 26, iOS 26, *) {
                Color.clear.glassEffect(.clear, in: outline)
            } else {
                outline.fill(.ultraThinMaterial).opacity(0.42)
            }
        }
        .background(.white.opacity(0.16), in: outline)
        .overlay {
            outline.strokeBorder(Theme.glassRim)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct TomatoMark: View {
    var body: some View {
        Canvas { context, size in
            var drawing = context
            drawing.scaleBy(x: size.width / 48, y: size.height / 48)

            let fruit = Path { path in
                path.move(to: CGPoint(x: 24, y: 14))
                path.addCurve(to: CGPoint(x: 3, y: 26), control1: CGPoint(x: 13.9, y: 10.3), control2: CGPoint(x: 3.3, y: 16.8))
                path.addCurve(to: CGPoint(x: 23.5, y: 42), control1: CGPoint(x: 2.5, y: 36.1), control2: CGPoint(x: 10.4, y: 42))
                path.addCurve(to: CGPoint(x: 45, y: 26.4), control1: CGPoint(x: 35.8, y: 42), control2: CGPoint(x: 45, y: 36.5))
                path.addCurve(to: CGPoint(x: 24, y: 14), control1: CGPoint(x: 45, y: 17), control2: CGPoint(x: 35.2, y: 9.7))
                path.closeSubpath()
            }
            drawing.fill(fruit, with: .linearGradient(
                Gradient(colors: [Theme.tomatoHighlight, Theme.tomatoBase]),
                startPoint: CGPoint(x: 17, y: 13),
                endPoint: CGPoint(x: 30, y: 43)
            ))

            let leaf = Path { path in
                path.move(to: CGPoint(x: 23.7, y: 14))
                path.addQuadCurve(to: CGPoint(x: 13, y: 8), control: CGPoint(x: 15.1, y: 12.8))
                path.addQuadCurve(to: CGPoint(x: 22.9, y: 10), control: CGPoint(x: 18.4, y: 7.1))
                path.addQuadCurve(to: CGPoint(x: 30.4, y: 4.9), control: CGPoint(x: 24.6, y: 5.7))
                path.addQuadCurve(to: CGPoint(x: 27.7, y: 11.5), control: CGPoint(x: 30.7, y: 8.6))
                path.addQuadCurve(to: CGPoint(x: 36.8, y: 11.9), control: CGPoint(x: 33, y: 9.8))
                path.addQuadCurve(to: CGPoint(x: 25.9, y: 16.7), control: CGPoint(x: 32.6, y: 15.9))
                path.addQuadCurve(to: CGPoint(x: 23.5, y: 18.9), control: CGPoint(x: 24.7, y: 17.9))
                path.closeSubpath()
            }
            drawing.fill(leaf, with: .color(Theme.leaf))

        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

extension View {
    func dashboardCard(fill: Color = Theme.card, usesGlassLens: Bool = true) -> some View {
        modifier(DashboardCardStyle(fill: fill, usesGlassLens: usesGlassLens))
    }
}

private struct DashboardCardStyle: ViewModifier {
    @Environment(\.usesGlassAppearance) private var glassEnabled
    let fill: Color
    let usesGlassLens: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: glassEnabled ? 25 : 22, style: .continuous)
        if glassEnabled {
            content
                .background {
                    ZStack {
                        shape.fill(fill.opacity(usesGlassLens ? 0.14 : 0.54))
                            .shadow(color: Theme.glassEdge.opacity(usesGlassLens ? 0.23 : 0.12), radius: 12, y: 6)
                        if usesGlassLens {
                            GlassLens(outline: shape)
                        } else {
                            shape.strokeBorder(Theme.glassRim)
                        }
                        shape.inset(by: 1).strokeBorder(.white.opacity(0.32), lineWidth: 0.6)
                    }
                    .allowsHitTesting(false)
                }
        } else {
            content.background(fill, in: shape)
                .overlay {
                    shape.strokeBorder(Theme.line, lineWidth: 1)
                        .allowsHitTesting(false)
                }
        }
    }
}

struct SoftButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.68 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

struct IconButton: View {
    let symbol: String
    let title: String
    var fill: Color = .clear
    var action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.usesGlassAppearance) private var glassEnabled
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(hovered && isEnabled ? Theme.ink : Theme.muted)
                .frame(width: 44, height: 44)
                .background {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(hovered && isEnabled ? Theme.track : fill.opacity(glassEnabled ? 0.78 : 1))
                        .padding(4)
                }
                .opacity(isEnabled ? 1 : 0.42)
                .contentShape(Rectangle())
        }
        .buttonStyle(SoftButtonStyle())
#if os(macOS)
        .onHover { hovered = $0 }
#endif
        .accessibilityLabel(title)
        .help(title)
    }
}
