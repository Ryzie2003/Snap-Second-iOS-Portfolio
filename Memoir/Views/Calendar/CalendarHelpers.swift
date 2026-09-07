//
//  CalendarHelpers.swift
//  Snap Second
//
//  Helper views and components for CalendarView
//

import SwiftUI
import Photos
import PhosphorSwift

// MARK: - Smart Fill Toast

struct SmartFillToast: View {
    let freshCount: Int
    var confirm: () -> Void
    var discard: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Ph.lightning.fill
                .color(.white)
                .frame(width: 22, height: 22)

            Text("Keep \(freshCount) Auto-Fill clips?")
                .font(.callout.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer(minLength: 10)

            Button("Save",    action: confirm)
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(Color.accentColor.opacity(0.25))
                )

            Button("Discard", role: .destructive, action: discard)
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(
                    Capsule()
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.45),
                        radius: 10, y: 6)
        )
        .frame(maxWidth: 340)
        .padding(.horizontal)
    }
}

// MARK: - Quick Icon Button

struct QuickIconButton: View {
    let symbol: String
    let bg: Color
    let fg: Color
    var size: CGFloat = 56
    var emphasis: Bool = true
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            iconView
                .color(fg)
                .frame(width: 37, height: 37)
                .frame(width: size, height: size)
                .background(
                    Circle()
                        .fill(bg)
                        .overlay(Circle().stroke(.white.opacity(0.18), lineWidth: 1))
                        .overlay(
                            emphasis
                            ? Circle().stroke(
                                LinearGradient(
                                    colors: [bg.opacity(0.0), bg.opacity(0.55)],
                                    startPoint: .top, endPoint: .bottom
                                ),
                                lineWidth: 3
                              )
                            : nil
                        )
                        .shadow(color: bg.opacity(0.45), radius: 12, y: 8)
                )
        }
        .buttonStyle(ScaledTap())
        .contentShape(Circle())
        .accessibilityLabel(Text(accessibilityTitle))
    }

    @ViewBuilder
    private var iconView: some View {
        switch symbol {
        case "camera.fill":
            Ph.camera.fill
        case "photo.on.rectangle":
            Ph.images.regular
        case "play.fill":
            Ph.play.fill
        case "plus":
            Ph.plus.bold
        default:
            Ph.circle.regular
        }
    }

    private var accessibilityTitle: String {
        switch symbol {
        case "photo.on.rectangle": return "Import from Library"
        case "camera.fill":        return "Capture"
        default:                   return "Create Montage"
        }
    }
}

// MARK: - Scaled Tap Button Style

struct ScaledTap: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

// MARK: - Grid Cell Borders

struct GridCellBorders: View {
    var color: Color
    var highlight: Color
    var line: CGFloat
    var drawRight: Bool
    var drawBottom: Bool

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            let half = line / 2

            ZStack {
                Path { p in
                    p.move(to: CGPoint(x: 0,       y: half));      p.addLine(to: CGPoint(x: w,       y: half))
                    p.move(to: CGPoint(x: half,    y: 0));         p.addLine(to: CGPoint(x: half,    y: h))
                    if drawRight  { p.move(to: CGPoint(x: w-half,  y: 0)); p.addLine(to: CGPoint(x: w-half,  y: h)) }
                    if drawBottom { p.move(to: CGPoint(x: 0,       y: h-half)); p.addLine(to: CGPoint(x: w,       y: h-half)) }
                }
                .stroke(color.opacity(0.90), lineWidth: line)

                Path { p in
                    p.move(to: CGPoint(x: 0,         y: half + line))
                    p.addLine(to: CGPoint(x: w,       y: half + line))
                    p.move(to: CGPoint(x: half + line, y: 0))
                    p.addLine(to: CGPoint(x: half + line, y: h))
                }
                .stroke(highlight.opacity(0.18), lineWidth: line)
            }
        }
    }
}

// MARK: - Scroll Fade Scale

struct ScrollFadeScale: ViewModifier {
    func body(content: Content) -> some View {
        let isSmallDevice = UIScreen.main.bounds.height < 700

        if #available(iOS 17.0, *), !isSmallDevice {
            content.scrollTransition(.interactive, axis: .vertical) { view, phase in
                view
                    .opacity(phase.isIdentity ? 1.0 : 0.2)
                    .scaleEffect(phase.isIdentity ? 1.0 : 0.9, anchor: .center)
            }
        } else {
            content
        }
    }
}

// MARK: - Smart Fill Sheet Host

struct SmartFillSheetHost: View {
    let T: Theme
    let project: Project
    let engine = SmartFillEngine()
    let onClose: () -> Void

    var body: some View {
        SmartFillRangeSheet(T: T, onRun: run, onClose: onClose)
    }

    private var run: (_ range: ClosedRange<Date>,
                      _ progress: @escaping @Sendable (Int, Int, Date, UIImage?) -> Void) async throws -> Void {
        { range, progress in
            try await engine.fillMissingDays(in: range, project: project, progress: progress)
        }
    }
}

// MARK: - Resolve Asset Day

func resolveAssetDay(_ localID: String?) -> Date {
    guard let id = localID else {
        return Calendar.current.startOfDay(for: Date())
    }
    let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
    let base = fetch.firstObject?.creationDate ?? Date()
    return Calendar.current.startOfDay(for: base)
}
