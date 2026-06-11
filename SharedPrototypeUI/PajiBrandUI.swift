import Foundation
import SwiftUI

enum PajiStrings {
    static func t(_ key: String) -> String {
        NSLocalizedString(key, tableName: nil, bundle: .main, value: key, comment: "")
    }
}

enum PajiTheme {
    static let navy = Color(red: 0.01, green: 0.03, blue: 0.10)
    static let panel = Color(red: 0.03, green: 0.07, blue: 0.15)
    static let panelElevated = Color(red: 0.05, green: 0.10, blue: 0.20)
    static let cyan = Color(red: 0.00, green: 0.86, blue: 0.88)
    static let mint = Color(red: 0.24, green: 0.90, blue: 0.67)
    static let lime = Color(red: 0.78, green: 0.95, blue: 0.13)
    static let pink = Color(red: 1.00, green: 0.13, blue: 0.48)
    static let ink = Color(red: 0.00, green: 0.02, blue: 0.08)
    static let textMuted = Color.white.opacity(0.62)
    static let border = Color.white.opacity(0.10)
    static let cardRadius: CGFloat = 10

    static let brandGradient = LinearGradient(
        colors: [cyan, mint, lime],
        startPoint: .leading,
        endPoint: .trailing
    )

    static let actionGradient = LinearGradient(
        colors: [cyan, mint, lime],
        startPoint: .leading,
        endPoint: .trailing
    )

    static let background = LinearGradient(
        colors: [
            Color(red: 0.00, green: 0.01, blue: 0.04),
            navy,
            Color(red: 0.01, green: 0.05, blue: 0.13),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

extension PajiStatusPill.Style {
    var userFacingSymbol: String {
        switch self {
        case .synced: return "checkmark.circle.fill"
        case .stable: return "waveform"
        case .warning: return "exclamationmark.triangle.fill"
        case .blocked: return "hand.raised.fill"
        }
    }
}

struct PajiLogoLockup: View {
    var compact = false

    var body: some View {
        HStack(alignment: .center, spacing: compact ? 7 : 10) {
            Text("啪叽")
                .font(.system(size: compact ? 24 : 42, weight: .black, design: .rounded))
                .italic()
                .foregroundStyle(PajiTheme.brandGradient)
                .shadow(color: PajiTheme.cyan.opacity(0.35), radius: 5, x: 0, y: 0)
            Text("Act")
                .font(.system(size: compact ? 24 : 38, weight: .heavy, design: .rounded))
                .italic()
                .foregroundStyle(.white)
            PulseLine()
                .stroke(PajiTheme.pink, style: StrokeStyle(lineWidth: compact ? 2.2 : 3.2, lineCap: .round, lineJoin: .round))
                .frame(width: compact ? 36 : 58, height: compact ? 16 : 22)
        }
        .accessibilityLabel("啪叽 Act")
    }
}

struct PajiPhoneHero: View {
    var connectionTitle: String
    var connectionSubtitle: String
    var statusStyle: PajiStatusPill.Style = .synced
    var action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PajiLogoLockup()
            Text(PajiStrings.t("brand.tagline"))
                .font(.headline.weight(.medium))
                .foregroundStyle(PajiTheme.textMuted)

            VStack(alignment: .leading, spacing: 18) {
                PajiProcessRow(number: 1, icon: .recordGesture, title: PajiStrings.t("onboarding.record.title"), subtitle: PajiStrings.t("onboarding.record.subtitle"))
                PajiProcessRow(number: 2, icon: .waveform, title: PajiStrings.t("onboarding.bind.title"), subtitle: PajiStrings.t("onboarding.bind.subtitle"))
                PajiProcessRow(number: 3, icon: .playBurst, title: PajiStrings.t("onboarding.trigger.title"), subtitle: PajiStrings.t("onboarding.trigger.subtitle"))
            }

            VStack(alignment: .leading, spacing: 8) {
                PajiStatusPill(style: statusStyle, title: connectionTitle)
                Text(connectionSubtitle)
                    .font(.footnote)
                    .foregroundStyle(PajiTheme.textMuted)
            }

            Button(action: action) {
                Text(PajiStrings.t("action.startSetup"))
                    .font(.headline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .foregroundStyle(PajiTheme.ink)
                    .background(PajiTheme.actionGradient)
                    .clipShape(Capsule())
                    .shadow(color: PajiTheme.cyan.opacity(0.22), radius: 12, x: 0, y: 6)
            }
            .buttonStyle(.plain)
        }
        .padding(22)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(PajiTheme.panel.opacity(0.92))
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(PajiTheme.cyan.opacity(0.20), lineWidth: 1)
                )
        )
    }
}

struct PajiFeatureStrip: View {
    var body: some View {
        HStack(spacing: 10) {
            PajiFeatureBadge(icon: .recordGesture, title: PajiStrings.t("feature.recordGesture"), subtitle: PajiStrings.t("feature.customActions"))
            PajiFeatureBadge(icon: .waveform, title: PajiStrings.t("feature.bindSound"), subtitle: PajiStrings.t("feature.anySound"))
            PajiFeatureBadge(icon: .playBurst, title: PajiStrings.t("feature.instantPlay"), subtitle: PajiStrings.t("feature.oneGesture"))
        }
    }
}

struct PajiActionWorkbench: View {
    var connectionTitle: String
    var connectionSubtitle: String
    var statusStyle: PajiStatusPill.Style
    var actionCount: Int
    var audioCount: Int
    var eventCount: Int
    var startAction: () -> Void
    var refreshAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center) {
                PajiLogoLockup(compact: true)
                Spacer()
                Button(action: refreshAction) {
                    Image(systemName: "arrow.clockwise")
                        .font(.headline.weight(.semibold))
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .foregroundStyle(PajiTheme.textMuted)
                .accessibilityLabel(PajiStrings.t("action.refresh"))
            }

            HStack(alignment: .center, spacing: 14) {
                PajiStatusOrb(style: statusStyle, glyph: statusStyle == .synced ? .watch : .sync, active: statusStyle != .blocked)
                    .frame(width: 78, height: 78)

                VStack(alignment: .leading, spacing: 8) {
                    PajiStatusPill(style: statusStyle, title: connectionTitle)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(connectionSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(PajiTheme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 8) {
                PajiMetricTile(value: "\(actionCount)", label: PajiStrings.t("home.metric.actions"), symbol: "hand.tap")
                PajiMetricTile(value: "\(audioCount)", label: PajiStrings.t("home.metric.sounds"), symbol: "waveform")
                PajiMetricTile(value: "\(eventCount)", label: PajiStrings.t("home.metric.events"), symbol: "applewatch")
            }

            Button(action: startAction) {
                Label(PajiStrings.t(actionCount == 0 ? "action.createFirstGesture" : "action.createGesture"), systemImage: "plus")
                    .font(.headline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .foregroundStyle(PajiTheme.ink)
                    .background(PajiTheme.actionGradient)
                    .clipShape(RoundedRectangle(cornerRadius: PajiTheme.cardRadius, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(PajiTheme.panel.opacity(0.90))
        .clipShape(RoundedRectangle(cornerRadius: PajiTheme.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: PajiTheme.cardRadius, style: .continuous)
                .stroke(PajiTheme.border, lineWidth: 1)
        )
    }
}

struct PajiMetricTile: View {
    var value: String
    var label: String
    var symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(PajiTheme.mint)
            Text(value)
                .font(.title3.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(.white)
            Text(label)
                .font(.caption2)
                .foregroundStyle(PajiTheme.textMuted)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(PajiTheme.panelElevated.opacity(0.74))
        .clipShape(RoundedRectangle(cornerRadius: PajiTheme.cardRadius, style: .continuous))
    }
}

struct PajiStatusOrb: View {
    var style: PajiStatusPill.Style
    var glyph: PajiGlyph
    var active = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let pulse = reduceMotion || !active ? 0 : (sin(time * 2.6) + 1) / 2

            ZStack {
                Circle()
                    .fill(PajiTheme.panelElevated.opacity(0.85))
                Circle()
                    .stroke(
                        LinearGradient(colors: style.colors, startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 2
                    )
                Circle()
                    .stroke(LinearGradient(colors: style.colors, startPoint: .leading, endPoint: .trailing), lineWidth: 1)
                    .scaleEffect(1.02 + pulse * 0.12)
                    .opacity(0.18 + pulse * 0.18)
                PajiGlyphView(glyph, size: 42)
            }
        }
        .accessibilityHidden(true)
    }
}

struct PajiSyncProgressBar: View {
    var progress: Double
    var isActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let shimmer = reduceMotion || !isActive ? 0 : (sin(time * 4.0) + 1) / 2
            GeometryReader { proxy in
                let clamped = min(max(progress, 0), 1)
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.10))
                    Capsule()
                        .fill(PajiTheme.actionGradient)
                        .frame(width: max(8, proxy.size.width * clamped))
                        .overlay(
                            Capsule()
                                .fill(Color.white.opacity(0.16 + shimmer * 0.16))
                                .blendMode(.screen)
                        )
                }
            }
        }
        .frame(height: 8)
        .accessibilityLabel(PajiStrings.t("sync.progress"))
        .accessibilityValue("\(Int((min(max(progress, 0), 1) * 100).rounded()))%")
    }
}

struct PajiStepRail: View {
    var currentIndex: Int
    var steps: [String]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, title in
                VStack(spacing: 5) {
                    Circle()
                        .fill(index <= currentIndex ? PajiTheme.brandGradient : LinearGradient(colors: [Color.white.opacity(0.16)], startPoint: .leading, endPoint: .trailing))
                        .frame(width: 12, height: 12)
                    Text(title)
                        .font(.caption2.weight(index == currentIndex ? .semibold : .regular))
                        .foregroundStyle(index == currentIndex ? .white : PajiTheme.textMuted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 2)
        .accessibilityElement(children: .combine)
    }
}

struct PajiFeatureBadge: View {
    var icon: PajiGlyph
    var title: String
    var subtitle: String

    var body: some View {
        VStack(spacing: 7) {
            PajiGlyphView(icon, size: 38)
            Text(title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(PajiTheme.textMuted)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .padding(.horizontal, 6)
        .background(PajiTheme.panelElevated.opacity(0.78))
        .clipShape(RoundedRectangle(cornerRadius: PajiTheme.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: PajiTheme.cardRadius, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }
}

struct PajiProcessRow: View {
    var number: Int
    var icon: PajiGlyph
    var title: String
    var subtitle: String

    var body: some View {
        HStack(spacing: 14) {
            PajiGlyphView(icon, size: 54)
                .frame(width: 66)
            ZStack {
                Circle()
                    .fill(PajiTheme.actionGradient)
                Text("\(number)")
                    .font(.caption.weight(.black))
                    .foregroundStyle(PajiTheme.ink)
            }
            .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline.weight(.semibold))
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(PajiTheme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct PajiStatusPill: View {
    enum Style: Equatable {
        case synced
        case stable
        case warning
        case blocked

        var colors: [Color] {
            switch self {
            case .synced, .stable: return [Color.green, PajiTheme.lime]
            case .warning: return [Color.yellow, Color.orange]
            case .blocked: return [PajiTheme.pink, Color(red: 1.00, green: 0.42, blue: 0.25)]
            }
        }

        var symbol: String {
            switch self {
            case .synced: return "checkmark.circle.fill"
            case .stable: return "waveform"
            case .warning: return "scope"
            case .blocked: return "hand.raised.fill"
            }
        }
    }

    var style: Style
    var title: String

    var body: some View {
        Label {
            Text(title)
                .font(.headline.weight(.semibold))
        } icon: {
            Image(systemName: style.symbol)
                .font(.headline.weight(.bold))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .foregroundStyle(LinearGradient(colors: style.colors, startPoint: .leading, endPoint: .trailing))
        .background(
            Capsule()
                .fill(PajiTheme.panelElevated.opacity(0.72))
                .overlay(
                    Capsule()
                        .stroke(LinearGradient(colors: style.colors, startPoint: .leading, endPoint: .trailing), lineWidth: 1.5)
                )
        )
    }
}

enum PajiGlyph {
    case recordGesture
    case waveform
    case playBurst
    case successBurst
    case watch
    case phone
    case sync
    case settings
    case log
    case test
}

struct PajiGlyphView: View {
    private let glyph: PajiGlyph
    private let size: CGFloat

    init(_ glyph: PajiGlyph, size: CGFloat) {
        self.glyph = glyph
        self.size = size
    }

    var body: some View {
        ZStack {
            switch glyph {
            case .recordGesture:
                RecordGestureGlyph()
            case .waveform:
                WaveformGlyph()
            case .playBurst:
                BurstBadgeGlyph(symbol: "play.fill")
            case .successBurst:
                BurstBadgeGlyph(symbol: "checkmark")
            case .watch:
                SystemGradientGlyph(systemName: "applewatch")
            case .phone:
                SystemGradientGlyph(systemName: "iphone")
            case .sync:
                SystemGradientGlyph(systemName: "arrow.triangle.2.circlepath")
            case .settings:
                SystemGradientGlyph(systemName: "gearshape")
            case .log:
                SystemGradientGlyph(systemName: "list.bullet.rectangle")
            case .test:
                SystemGradientGlyph(systemName: "scope")
            }
        }
        .frame(width: size, height: size)
    }
}

private struct SystemGradientGlyph: View {
    var systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 34, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(PajiTheme.brandGradient)
    }
}

private struct WaveformGlyph: View {
    private let bars: [CGFloat] = [0.26, 0.48, 0.70, 1.00, 0.70, 0.48, 0.26]

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            HStack(alignment: .center, spacing: width * 0.055) {
                ForEach(Array(bars.enumerated()), id: \.offset) { index, value in
                    RoundedRectangle(cornerRadius: width * 0.035, style: .continuous)
                        .fill(index < 3 ? PajiTheme.cyan : (index == 3 ? PajiTheme.mint : PajiTheme.lime))
                        .frame(width: max(3, width * 0.095), height: height * value * 0.78)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct RecordGestureGlyph: View {
    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            ZStack {
                ArcShape(start: .degrees(206), end: .degrees(350))
                    .stroke(PajiTheme.brandGradient, style: StrokeStyle(lineWidth: side * 0.10, lineCap: .round))
                    .frame(width: side * 0.96, height: side * 0.96)
                    .rotationEffect(.degrees(-8))
                Image(systemName: "hand.fist.fill")
                    .font(.system(size: side * 0.54, weight: .black))
                    .foregroundStyle(.white)
                    .shadow(color: PajiTheme.cyan, radius: 0, x: -2, y: 2)
                    .shadow(color: PajiTheme.ink, radius: 0, x: 2, y: -2)
                    .rotationEffect(.degrees(8))
                Image(systemName: "applewatch")
                    .font(.system(size: side * 0.30, weight: .bold))
                    .foregroundStyle(PajiTheme.lime)
                    .shadow(color: PajiTheme.ink, radius: 0, x: 1.4, y: 1.4)
                    .offset(x: -side * 0.18, y: side * 0.20)
                BurstBadgeGlyph(symbol: "waveform")
                    .frame(width: side * 0.42, height: side * 0.42)
                    .offset(x: side * 0.30, y: -side * 0.26)
            }
        }
    }
}

private struct BurstBadgeGlyph: View {
    var symbol: String

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            ZStack {
                BurstShape(points: 16, innerRatio: 0.74)
                    .stroke(PajiTheme.brandGradient, style: StrokeStyle(lineWidth: side * 0.055, lineJoin: .round))
                    .shadow(color: PajiTheme.cyan.opacity(0.4), radius: 2)
                Image(systemName: symbol)
                    .font(.system(size: side * 0.42, weight: .black))
                    .foregroundStyle(symbol == "play.fill" ? PajiTheme.ink : PajiTheme.mint)
            }
            .padding(side * 0.05)
        }
    }
}

struct PajiWatchStatusCard: View {
    var title: String
    var subtitle: String
    var glyph: PajiGlyph
    var style: PajiStatusPill.Style = .stable
    var isActive = false
    var triggerCount: Int

    var body: some View {
        VStack(spacing: 11) {
            PajiLogoLockup(compact: true)
            PajiStatusOrb(style: style, glyph: glyph, active: isActive)
                .frame(width: 82, height: 82)
            Text(title)
                .font(.headline.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(subtitle)
                .font(.footnote)
                .foregroundStyle(PajiTheme.textMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if triggerCount > 0 {
                PajiStatusPill(style: .stable, title: "\(PajiStrings.t("watch.triggerCount")) \(triggerCount)")
                    .font(.caption)
            }
            if style == .synced || style == .stable {
                PajiSyncProgressBar(progress: 1, isActive: isActive)
                    .padding(.top, 2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(PajiTheme.panel.opacity(0.88))
        .clipShape(RoundedRectangle(cornerRadius: PajiTheme.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: PajiTheme.cardRadius, style: .continuous)
                .stroke(PajiTheme.cyan.opacity(0.20), lineWidth: 1)
        )
    }
}

private struct PulseLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let y = rect.midY
        path.move(to: CGPoint(x: rect.minX, y: y))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.32, y: y))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.43, y: rect.minY + rect.height * 0.28))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.52, y: rect.maxY - rect.height * 0.18))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.62, y: rect.minY + rect.height * 0.10))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.70, y: y))
        path.addLine(to: CGPoint(x: rect.maxX, y: y))
        return path
    }
}

private struct ArcShape: Shape {
    var start: Angle
    var end: Angle

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addArc(
            center: CGPoint(x: rect.midX, y: rect.midY),
            radius: min(rect.width, rect.height) / 2,
            startAngle: start,
            endAngle: end,
            clockwise: false
        )
        return path
    }
}

private struct BurstShape: Shape {
    var points: Int
    var innerRatio: CGFloat

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2
        let inner = outer * innerRatio
        var path = Path()

        for i in 0..<(points * 2) {
            let angle = CGFloat(i) / CGFloat(points * 2) * .pi * 2 - .pi / 2
            let radius = i.isMultiple(of: 2) ? outer : inner
            let point = CGPoint(
                x: center.x + cos(angle) * radius,
                y: center.y + sin(angle) * radius
            )
            if i == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }

        path.closeSubpath()
        return path
    }
}
