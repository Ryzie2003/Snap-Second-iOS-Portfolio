//
//  OnboardingOverlay.swift
//  Memoir
//
//  White text, "days" appended, one line at a time,
//  timer-based integer ticking, fade in/out with gap (no overlap), no slide transitions
//

import SwiftUI

// Timer-based 1-by-1 counter (respects Reduce Motion)
struct AnimatedCountLine: View {
    let show: Bool
    let fontSize: CGFloat
    let fontWeight: Font.Weight
    let start: Int = 26_980
    let end: Int = 27_000
    /// Total time for the whole count (seconds)
    let duration: Double = 0.9

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var current: Int = 26_980
    @State private var running = false

    private var steps: Int { max(end - start, 1) }
    private var stepInterval: Double { max(duration / Double(steps), 0.02) }

    var body: some View {
        // Build a timer tied to the computed step interval
        let timer = Timer.publish(every: stepInterval, on: .main, in: .common).autoconnect()

        Text(current.formatted(.number.grouping(.automatic)))
            .font(OnboardingTypography.fixed(fontSize, weight: fontWeight))
            .foregroundColor(.white)
            .monospacedDigit()
            .onAppear {
                if reduceMotion {
                    current = end
                    running = false
                } else {
                    current = start
                    running = show
                }
            }
            .onChange(of: show) { visible in
                if reduceMotion {
                    current = end
                    running = false
                } else {
                    if visible {
                        current = start
                        running = true
                    } else {
                        running = false
                    }
                }
            }
            .onReceive(timer) { _ in
                guard running, !reduceMotion else { return }
                if current < end {
                    // Optional tiny animation per tick
                    withAnimation(.linear(duration: 0.06)) {
                        current += 1
                    }
                } else {
                    running = false
                }
            }
    }
}

struct OnboardingOverlay: View {
    let time: TimeInterval        // current time in the loop (0...loopLength)
    let loopLength: TimeInterval  // e.g., 15.7
    let beats = OnboardingBeats.beats
    let subline = OnboardingBeats.subline

    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private var overlayHorizontalPadding: CGFloat {
        verticalSizeClass == .compact ? 20 : 24
    }

    private var overlayBottomPadding: CGFloat {
        verticalSizeClass == .compact ? 102 : 122
    }

    private var leadInFontSize: CGFloat {
        verticalSizeClass == .compact ? 21 : 24
    }

    private var countFontSize: CGFloat {
        verticalSizeClass == .compact ? 40 : 46
    }

    private var beatFontSize: CGFloat {
        verticalSizeClass == .compact ? 26 : 30
    }

    // Active beat = only one line shown at a time
    private func activeBeat(at t: TimeInterval) -> Beat? {
        beats.first { t >= $0.start && t < $0.end }
    }

    // Fade profile with a tiny "dead zone" gap so lines don't overlap visually.
    private func opacityFor(time t: TimeInterval, in beat: Beat) -> Double {
        let total = beat.end - beat.start
        guard total > 0 else { return 1 }

        let x = t - beat.start
        let gap: TimeInterval = 0.18      // blank time at start/end
        let fade: TimeInterval = 0.60     // fade in/out duration

        // Before/after beat, or inside the intentional gaps
        if x < 0 || x > total { return 0 }
        if x < gap { return 0 }
        if x > total - gap { return 0 }

        // Fade in
        if x < gap + fade {
            return (x - gap) / fade
        }

        // Fade out
        if x > (total - gap - fade) {
            return (total - gap - x) / fade
        }

        // Hold
        return 1
    }

    var body: some View {
        if let beat = activeBeat(at: time) {
            let op = opacityFor(time: time, in: beat)

            VStack(spacing: 8) {
                if beat.text.contains("27,000") {
                    // First beat: header + animated number + "days"
                    Text("The average person lives about")
                        .font(OnboardingTypography.fixed(leadInFontSize, weight: .medium))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)

                    HStack(spacing: 4) {
                        AnimatedCountLine(
                            show: op > 0.0,
                            fontSize: countFontSize,
                            fontWeight: .semibold
                        )
                        Text("days")
                            .font(OnboardingTypography.fixed(countFontSize, weight: .semibold))
                            .foregroundColor(.white)
                    }
                } else {
                    Text(beat.text)
                        .font(OnboardingTypography.fixed(beatFontSize, weight: .semibold))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                }

                if let sub = subline {
                    Text(sub)
                        .font(OnboardingTypography.fixed(15, weight: .regular))
                        .foregroundColor(.white.opacity(0.9))
                        .multilineTextAlignment(.center)
                }
            }
            // No transitions — opacity only, driven by time so no crossfade overlap.
            .opacity(op)
            .padding(.horizontal, overlayHorizontalPadding)
            .padding(.bottom, overlayBottomPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .allowsHitTesting(false)
        } else {
            // No active beat (e.g., during gaps)
            Color.clear
                .padding(.horizontal, overlayHorizontalPadding)
                .padding(.bottom, overlayBottomPadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .allowsHitTesting(false)
        }
    }
}
