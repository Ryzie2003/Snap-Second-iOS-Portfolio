import SwiftUI
import UIKit

// MARK: - Smart Fill (Simple, Professional UI)

struct SmartFillRangeSheet: View {
    let T: Theme

    /// Engine runner provided by caller.
    /// - progress: (index, total, day, thumbnail)
    let onRun: SmartFillRunner

    /// Called when the panel should close (cancel or success).
    let onClose: () -> Void

    @State private var monthChoices: [Date] = []
    @State private var selectedMonth: Date = Calendar.current.startOfMonth(for: Date())

    // HUD state
    @State private var isRunning = false
    @State private var currentIndex = 0
    @State private var totalCount = 0
    @State private var currentDay: Date? = nil
    @State private var currentThumb: UIImage? = nil
    @State private var runningTask: Task<Void, Never>? = nil
    @State private var lastError: String?

    var body: some View {
        ZStack {
            // Main panel content
            VStack(spacing: 18) {
                // Grab handle (optional – still looks nice inside a card)
                Capsule()
                    .frame(width: 40, height: 5)
                    .foregroundStyle(T.textSecondary.opacity(0.35))
                    .padding(.top, 4)

                // TITLE + SHORT LINE
                VStack(spacing: 4) {
                    Text("Smart Fill")
                        .font(.system(.title2, design: .rounded).weight(.semibold))
                        .foregroundStyle(T.core.text)

                    Text("Select a month to fill empty days.")
                        .font(.system(.footnote, design: .rounded))
                        .foregroundStyle(T.textSecondary)
                }
                .padding(.top, 4)

                // MONTH PICKER CARD (title + picker on same line)
                HStack {
                    Spacer(minLength: 0)
                    Picker(selection: $selectedMonth) {
                        ForEach(monthChoices, id: \.self) { month in
                            Text(month.formatted(.dateTime.year().month(.wide))).tag(month)
                        }
                    } label: {
                        Text(selectedMonth.formatted(.dateTime.year().month(.wide)))
                            .font(.system(.subheadline, design: .rounded).weight(.semibold))
                            .foregroundStyle(T.core.accent)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                            .frame(maxWidth: 200)
                            .multilineTextAlignment(.center)
                    }
                    .pickerStyle(.menu)
                    .tint(T.core.accent)
                    .accessibilityLabel("Month")
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(T.border.opacity(0.4), lineWidth: 0.8)
                        )
                )
                .padding(.horizontal, 2)

                if let lastError {
                    Text(lastError)
                        .font(.system(.footnote, design: .rounded))
                        .foregroundStyle(.red)
                        .padding(.horizontal, 4)
                }

                Spacer(minLength: 4)

                // BUTTON ROW
                HStack(spacing: 12) {
                    Button("Cancel") {
                        onClose()
                    }
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .buttonStyle(.bordered)
                    .tint(T.textSecondary.opacity(0.85))

                    Spacer()

                    Button {
                        startRun()
                    } label: {
                        HStack(spacing: 8) {
                            if isRunning {
                                ProgressView()
                                    .scaleEffect(0.9)
                            }
                            Text(isRunning ? "Running…" : "Run Smart Fill")
                                .font(.system(.body, design: .rounded).weight(.semibold))
                        }
                        .padding(.horizontal, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(T.core.accent)
                    .disabled(isRunning)
                }
            }
            .padding(20)
            .frame(maxWidth: 360)
            .fixedSize(horizontal: false, vertical: true)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(T.core.surface)   // ← solid white / linen theme background
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(T.border.opacity(0.25), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.10), radius: 8, y: 4)
            )
        }
        .onAppear(perform: bootstrapMonths)
        .overlay(progressHUD)
        .tint(T.core.accent)
    }

    // MARK: - Minimal, Professional HUD
    // Big square thumbnail, X in top-right, small counter in bottom-right.

    @ViewBuilder
    private var progressHUD: some View {
        if isRunning, totalCount > 0 {
            ZStack {
                Color.black.opacity(0.30).ignoresSafeArea()

                ZStack {
                    // Glass card
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .shadow(color: .black.opacity(0.45), radius: 18, y: 10)

                    // Thumbnail fills inner square
                    ZStack {
                        if let ui = currentThumb {
                            Image(uiImage: ui)
                                .resizable()
                                .scaledToFill()
                                .clipped()
                        } else {
                            Image(systemName: "photo")
                                .font(.system(size: 40))
                                .foregroundStyle(T.textSecondary.opacity(0.9))
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .padding(10)
                }
                .frame(width: 230, height: 230)
                .overlay(
                    // Cancel button (top-right)
                    Button {
                        runningTask?.cancel()
                    } label: {
                        ZStack {
                            Circle()
                                .fill(Color.black.opacity(0.55))
                            Image(systemName: "xmark")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                        .frame(width: 28, height: 28)
                        .padding(8)
                    },
                    alignment: .topTrailing
                )
                .overlay(
                    // Small counter (bottom-right)
                    Text("\(currentIndex)/\(max(totalCount, currentIndex))")
                        .font(.system(.caption2, design: .rounded).weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.black.opacity(0.65))
                        )
                        .foregroundStyle(.white)
                        .padding(8),
                    alignment: .bottomTrailing
                )
                .padding(.horizontal, 24)
            }
            .transition(.opacity)
        }
    }

    // MARK: - Actions

    private func startRun() {
        guard !isRunning else { return }
        lastError = nil

        let start = Calendar.current.startOfMonth(for: selectedMonth)
        let end   = Calendar.current.endOfMonth(for: selectedMonth)
        let range = start...end

        isRunning = true
        currentIndex = 0
        totalCount = Calendar.current.numberOfDays(in: range)
        currentDay = nil
        currentThumb = nil

        runningTask = Task {
            defer {
                isRunning = false
                runningTask = nil
            }

            do {
                try await onRun(range) { idx, total, day, thumb in
                    Task { @MainActor in
                        self.currentIndex = idx
                        self.totalCount   = max(total, self.totalCount)
                        self.currentDay   = day
                        self.currentThumb = thumb
                    }
                }
                await MainActor.run {
                    onClose()
                }  // auto-dismiss on success
            } catch is CancellationError {
                // User cancelled
            } catch {
                await MainActor.run { lastError = error.localizedDescription }
            }
        }
    }

    private func bootstrapMonths() {
        guard monthChoices.isEmpty else { return }
        var months: [Date] = []
        let now = Calendar.current.startOfMonth(for: Date())
        for i in 0..<24 {
            if let d = Calendar.current.date(byAdding: .month, value: -i, to: now) {
                months.append(d)
            }
        }
        monthChoices = months
        selectedMonth = months.first ?? now
    }
}

// MARK: - Calendar helpers

fileprivate extension Calendar {
    func startOfMonth(for date: Date) -> Date {
        let comps = dateComponents([.year, .month], from: date)
        return self.date(from: comps)!
    }
    func endOfMonth(for date: Date) -> Date {
        let start = startOfMonth(for: date)
        var comps = DateComponents(); comps.month = 1; comps.day = -1
        let lastDay = self.date(byAdding: comps, to: start)!
        return self.date(
            bySettingHour: 23, minute: 59, second: 59,
            of: lastDay
        )!
    }
    func numberOfDays(in range: ClosedRange<Date>) -> Int {
        let start = startOfDay(for: range.lowerBound)
        let end   = startOfDay(for: range.upperBound)
        guard let days = dateComponents([.day], from: start, to: end).day else { return 0 }
        return days + 1
    }
}
