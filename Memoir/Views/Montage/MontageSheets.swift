//
//  MontageSheets.swift
//  Snap Second
//
//  Sheet scaffolds and control shelves for Montage
//

import SwiftUI
import UIKit
import PhosphorSwift
import UniformTypeIdentifiers

// MARK: - Activity View

struct ActivityView: UIViewControllerRepresentable {
    var activityItems: [Any]
    func makeUIViewController(context: Context) ->
        UIActivityViewController {
        UIActivityViewController(activityItems: activityItems,
                                 applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController,
                                context: Context) { }
}

// MARK: - Empty Range Screen

struct EmptyRangeScreen: View {
    let T: Theme
    let label: String
    var onPickRange: () -> Void
    var onCapture: (() -> Void)? = nil

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14)
                .fill(T.core.surface.opacity(0.6))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(T.border.opacity(0.6)))
                .shadow(radius: 4, y: 2)

            VStack(spacing: 12) {
                Image(systemName: "film.stack")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(T.textSecondary)

                Text("No clips in \(label.isEmpty ? "this range" : label)")
                    .font(.system(.headline, design: .rounded).weight(.semibold))
                    .foregroundStyle(T.core.text)

                Text("Choose a different date range or add a new memory.")
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(T.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(20)
        }
    }
}

// MARK: - Date Range Picker

struct DateRangePicker: View {
    let T: Theme
    @Binding var range: DateInterval
    var onDone: () -> Void

    @State private var start: Date
    @State private var end:   Date

    init(T: Theme, range: Binding<DateInterval>, onDone: @escaping () -> Void) {
        self.T = T
        _range = range
        _start = State(initialValue: range.wrappedValue.start)
        _end   = State(initialValue: range.wrappedValue.end)
        self.onDone = onDone
    }

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("From", selection: $start, displayedComponents: .date)
                    .font(.system(.body, design: .rounded))
                DatePicker("To",   selection: $end,   displayedComponents: .date)
                    .font(.system(.body, design: .rounded))
            }
            .scrollContentBackground(.hidden)
            .background(T.core.surface)
            .tint(T.core.accent)
            .navigationTitle("Choose Range")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        // Ensure end >= start to prevent DateInterval crash
                        let validStart = min(start, end)
                        let validEnd = max(start, end)
                        range = DateInterval(start: validStart, end: validEnd)
                        onDone()
                    }
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(T.core.accent)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onDone() }
                        .foregroundStyle(T.textSecondary)
                }
            }
        }
    }
}

// MARK: - Pro Preview Banner

struct ProPreviewBanner: View {
    var accent: Color
    var onUpgrade: () -> Void

    private var responsiveHeight: CGFloat {
        let h = UIScreen.main.bounds.height
        return max(44, min(66, h * 0.045))
    }

    var body: some View {
        HStack {
            HStack(spacing: 8) {
                ZStack {
                    Ph.sparkle.fill
                        .color(.white)
                        .font(.system(size: 14, weight: .semibold))
                }
                .frame(width: 16, height: 16)
                .clipped()

                Text("Previewing with Pro Features")
                    .font(.system(.caption, design: .rounded).weight(.medium))
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)

                Button("Upgrade") {
                    onUpgrade()
                }
                .font(.system(.caption2, design: .rounded).weight(.semibold))
                .padding(.horizontal, 8)
                .padding(
                    .vertical,
                    UIScreen.main.bounds.height < 700 ? 4 : 6
                )
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(0.14))
                )
                .contentShape(Rectangle())
            }
            .foregroundColor(.white)
        }
        .padding(.horizontal, 12)
        .frame(height: responsiveHeight)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(
                gradient: Gradient(colors: [
                    accent.opacity(0.95),
                    accent.opacity(0.85)
                ]),
                startPoint: .leading,
                endPoint: .trailing
            )
            .ignoresSafeArea(edges: .top)
        )
        .overlay(
            Divider()
                .background(Color.white.opacity(0.35)),
            alignment: .bottom
        )
    }
}

// MARK: - Sheet Scaffold

struct SheetScaffold<Content: View>: View {
    let title: String
    let T: Theme
    @ViewBuilder var content: Content
    var detents: [PresentationDetent] = [.medium, .large]
    var useScroll: Bool = true

    @Binding var selectedDetent: PresentationDetent

    init(title: String, T: Theme, detents: [PresentationDetent], useScroll: Bool,
         selectedDetent: Binding<PresentationDetent> = .constant(.medium),
         @ViewBuilder content: () -> Content) {
        self.title = title; self.T = T; self.content = content()
        self.detents = detents; self.useScroll = useScroll
        _selectedDetent = selectedDetent
    }

    var body: some View {
        NavigationStack {
            ZStack {
                T.core.surface.ignoresSafeArea()

                Group {
                    if useScroll {
                        ScrollView { inner }
                            .scrollIndicators(.hidden)
                    } else {
                        inner
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { DismissButton(T: T) }
            }
        }
        .presentationDetents(Set(detents), selection: $selectedDetent)
        .presentationDragIndicator(.visible)
        .ifAvailable_iOS16_4 {
            $0.presentationCornerRadius(24)
                .presentationBackground(T.core.surface)
        }
    }

    private var inner: some View {
        VStack(spacing: 12) {
            content
                .font(.system(.body, design: .rounded))
                .foregroundStyle(T.core.text)
                .tint(T.core.accent)
        }
        .padding(16)
    }
}

private struct DismissButton: View {
    @Environment(\.dismiss) var dismiss
    let T: Theme
    var body: some View {
        Button("Done") { dismiss() }
            .font(.system(.callout, design: .rounded).weight(.semibold))
            .foregroundStyle(T.core.accent)
    }
}

private extension View {
    @ViewBuilder
    func ifAvailable_iOS16_4<Wrapped: View>(
        _ transform: (Self) -> Wrapped
    ) -> some View {
        if #available(iOS 16.4, *) {
            transform(self)
        } else {
            self
        }
    }
}
