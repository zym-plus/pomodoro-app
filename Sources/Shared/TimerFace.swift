import SwiftUI

extension TimerMode {
    var title: String {
        switch self {
        case .focus: "Focus"
        case .shortBreak: "Short Break"
        case .longBreak: "Long Break"
        }
    }

    var completionTitle: String {
        switch self {
        case .focus: "Focus Session Complete"
        case .shortBreak, .longBreak: "Break Complete"
        }
    }

    var completionBody: String {
        switch self {
        case .focus: "Take a short break away from the screen."
        case .shortBreak, .longBreak: "Start your next focus session when you're ready."
        }
    }

    var symbol: String {
        switch self {
        case .focus: "timer"
        case .shortBreak: "cup.and.saucer"
        case .longBreak: "moon.zzz"
        }
    }
}

struct TimerFace: View {
    static let horizontalPadding: CGFloat = 20
    private static let verticalPadding: CGFloat = 20
    private static let spacing: CGFloat = 17
    private static let controlHeight: CGFloat = 44
    private static let noiseSpacing: CGFloat = 4

    static func heightOutsideDial(mode: TimerMode, usesOpenLayout: Bool) -> CGFloat {
        let padding = usesOpenLayout ? 0 : verticalPadding
        let timerHeight = 2 * (padding + spacing + controlHeight)
        return mode == .focus ? timerHeight + noiseSpacing + controlHeight : timerHeight
    }

    @ObservedObject var store: PomodoroStore
    @Binding var whiteNoiseEnabled: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicType
    @Environment(\.usesGlassAppearance) private var glassEnabled
#if os(iOS)
    @State private var playbackFeedback = false
#endif
    let maximumDiameter: CGFloat
    let keyboardShortcutsEnabled: Bool
    let usesOpenLayout: Bool

    private var snapshot: PomodoroSnapshot { store.snapshot }
    private var modePickerWidth: CGFloat { 284 + max(0, maximumDiameter - 420) * 0.44 }

    var body: some View {
        Group {
            if usesOpenLayout {
                timerContent
            } else {
                timerContent
                    .padding(.horizontal, Self.horizontalPadding)
                    .padding(.vertical, Self.verticalPadding)
                    .dashboardCard(fill: Theme.timerSurface)
            }
        }
#if os(iOS)
        .sensoryFeedback(.selection, trigger: playbackFeedback)
#endif
    }

    private var timerContent: some View {
        VStack(spacing: Self.spacing) {
            modePicker
                .frame(maxWidth: modePickerWidth)

            GeometryReader { geometry in
                face(diameter: min(geometry.size.width, geometry.size.height))
            }
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: maximumDiameter)

            VStack(spacing: Self.noiseSpacing) {
                controls
                if snapshot.mode == .focus {
                    whiteNoiseToggle
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func face(diameter: CGFloat) -> some View {
        let growth = max(0, diameter - 420)
        let stroke = 5 + growth * 0.012
        let markSize = 25 + growth * 0.04
        let digitLimit = 97 + growth * 0.22
        let remainingFraction = Double(snapshot.remaining) / Double(max(snapshot.duration, 1))
        let elapsed = max(0, min(1, 1 - remainingFraction))
        let countdown = String(format: "%02d:%02d", snapshot.remaining / 60, snapshot.remaining % 60)
        let spokenTime = Duration.seconds(snapshot.remaining).formatted(.units(
            allowed: [.minutes, .seconds],
            width: .wide
        ).locale(Locale(identifier: "en_US")))

        return ZStack {
            if usesOpenLayout && glassEnabled {
                Circle()
                    .fill(LinearGradient(
                        colors: [.white.opacity(0.46), .white.opacity(0.12)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .overlay { Circle().strokeBorder(.white.opacity(0.68), lineWidth: 1) }
            } else if glassEnabled {
                GlassLens(outline: Circle())
            } else {
                Circle().fill(Theme.card)
            }
            Circle()
                .strokeBorder(
                    usesOpenLayout && glassEnabled ? Theme.accentDark.opacity(0.12)
                        : Theme.accentSoft.opacity(glassEnabled ? 0.64 : 0.78),
                    lineWidth: stroke
                )
            Circle()
                .inset(by: stroke / 2)
                .trim(from: 0, to: max(0.001, elapsed))
                .stroke(
                    Theme.accent,
                    style: StrokeStyle(lineWidth: stroke, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(reduceMotion ? nil : .easeOut(duration: 0.28), value: elapsed)
                .accessibilityHidden(true)

            VStack(spacing: 6 + growth * 0.018) {
                Group {
                    if snapshot.mode == .focus {
                        TomatoMark()
                    } else {
                        Image(systemName: snapshot.mode.symbol)
                            .font(.system(size: markSize * 0.68, weight: .medium))
                            .foregroundStyle(Theme.accentDark)
                    }
                }
                .frame(width: markSize, height: markSize)
                .accessibilityHidden(true)

                Text(countdown)
                    .font(.system(size: min(digitLimit, diameter * (countdown.count > 5 ? 0.223 : 0.27)), weight: .light))
                    .monospacedDigit()
                    .tracking(-1.7)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .foregroundStyle(Theme.ink)
                    .contentTransition(reduceMotion ? .identity : .numericText(countsDown: true))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: countdown)
                    .accessibilityLabel("\(spokenTime) remaining")

                Text("Round \(snapshot.round) of 4")
                    .font(.footnote)
                    .monospacedDigit()
                    .foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, diameter * 0.095)
        }
        .frame(width: diameter, height: diameter)
    }

    @ViewBuilder
    private var modePicker: some View {
        if dynamicType.isAccessibilitySize {
            Menu {
                ForEach(TimerMode.allCases) { mode in
                    let selected = mode == snapshot.mode
                    Button {
                        if !selected { store.setMode(mode) }
                    } label: {
                        if selected {
                            Label(mode.title, systemImage: "checkmark")
                        } else {
                            Text(mode.title)
                        }
                    }
                }
            } label: {
                HStack {
                    Text(snapshot.mode.title)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.footnote)
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.accentDark)
                .padding(.horizontal, 12)
                .frame(minHeight: Self.controlHeight)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
            }
            .accessibilityLabel("Timer Mode")
            .accessibilityValue(snapshot.mode.title)
        } else {
            modeSegments
        }
    }

    private var modeSegments: some View {
        HStack(spacing: 2) {
            ForEach(TimerMode.allCases) { mode in
                let selected = mode == snapshot.mode
                Button {
                    if !selected { store.setMode(mode) }
                } label: {
                    Text(mode.title)
                        .font(.subheadline.weight(selected ? .semibold : .medium))
                        .foregroundStyle(selected ? Theme.accentDark : Theme.muted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.74)
                        .padding(.horizontal, 5)
                        .frame(maxWidth: .infinity, minHeight: Self.controlHeight - 10)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 9)
                                    .fill(glassEnabled ? .white.opacity(0.56) : Theme.card)
                                    .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
                            }
                        }
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                }
                .buttonStyle(SoftButtonStyle())
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityRemoveTraits(selected ? [] : .isSelected)
            }
        }
        .padding(.horizontal, 4)
        .background {
            let shape = RoundedRectangle(cornerRadius: 13)
            if glassEnabled {
                GlassLens(outline: shape)
            } else {
                shape.fill(Theme.track.opacity(0.72))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Timer Mode")
    }

    private var startTitle: String {
        if snapshot.running { return "Pause" }
        return snapshot.hasElapsed ? "Resume" : "Start"
    }

    private var whiteNoiseToggle: some View {
        Toggle(isOn: $whiteNoiseEnabled) {
            Label("White Noise", systemImage: "waveform")
                .font(.footnote.weight(.medium))
                .foregroundStyle(Theme.muted)
        }
        .toggleStyle(.switch)
        .fixedSize(horizontal: !dynamicType.isAccessibilitySize, vertical: false)
        .frame(maxWidth: 248, minHeight: Self.controlHeight)
        .help("Play white noise while the focus timer runs")
        .accessibilityHint("Plays while the focus timer runs.")
    }

    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                resetButton
                playbackButton
                skipButton
            }
            .fixedSize(horizontal: true, vertical: false)

            VStack(spacing: 8) {
                playbackButton
                HStack(spacing: 10) {
                    resetButton
                    skipButton
                }
            }
        }
    }

    private var resetButton: some View {
        IconButton(symbol: "arrow.counterclockwise", title: "Reset Timer", fill: Theme.card) {
            store.reset()
        }
        .disabled(!snapshot.running && !snapshot.hasElapsed)
    }

    private var playbackButton: some View {
        Button {
            store.toggle()
#if os(iOS)
            playbackFeedback.toggle()
#endif
        } label: {
            HStack(spacing: 9) {
                Image(systemName: snapshot.running ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .accessibilityHidden(true)
                Text(startTitle)
                    .font(.body.weight(.semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 19)
            .padding(.vertical, 6)
            .frame(minWidth: 128, minHeight: Self.controlHeight)
            .background {
                Capsule().fill(Theme.action)
                    .shadow(color: glassEnabled ? Theme.accentDark.opacity(0.26) : .clear, radius: 8, y: 4)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(SoftButtonStyle())
        .keyboardShortcut(keyboardShortcutsEnabled ? KeyboardShortcut(.space, modifiers: []) : nil)
        .help("\(startTitle) (Space)")
    }

    private var skipButton: some View {
        IconButton(symbol: "forward.end", title: "Skip Session", fill: Theme.card) {
            store.skip()
        }
    }
}
