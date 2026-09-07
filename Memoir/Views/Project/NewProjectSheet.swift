import SwiftUI
import PhosphorSwift

struct NewProjectSheet: View {
    let T: Theme
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var store: ProjectStore
    @EnvironmentObject var entitlements: Entitlements
    @State private var showLimitAlert = false


    // Let the parent (ProjectsView) push to CalendarView after creation
    var onCreateID: ((Project.ID) -> Void)? = nil

    enum ProjectMode: String, CaseIterable, Identifiable {
        case dailyJournal = "Daily Journal"
        case timelapse    = "Timelapse"
        case collections  = "Collections"
        var id: String { rawValue }

        var icon: String {
            switch self {
            case .dailyJournal: return "calendar.badge.clock"
            case .timelapse:    return "film.stack"
            case .collections:  return "square.grid.2x2"
            }
        }
        var subtitle: String {
            switch self {
            case .dailyJournal: return "Capture a short daily entry with text and clips."
            case .timelapse:    return "Add clips over time to stitch into a seamless montage."
            case .collections:  return "Organize any clips you want—no timeline required."
            }
        }

        var projectType: ProjectType {
            switch self {
            case .dailyJournal: return .dailyJournal
            case .timelapse: return .timelapse
            case .collections: return .collections
            }
        }
    }

    @State private var name: String = ""
    @State private var selectedMode: ProjectMode = .dailyJournal

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Scrollable form content
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {

                        // Sheet header
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Create a New Project")
                                .font(.system(size: 24, weight: .bold, design: .rounded))
                                .foregroundStyle(T.core.text)
                                .accessibilityAddTraits(.isHeader)
                        }
                        .padding(.bottom, 6)


                        // Name
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Name")
                                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                            TextField("My Journal", text: $name)
                                .textInputAutocapitalization(.words)
                                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                                .submitLabel(.done)
                                .padding(12)
                                .background(T.core.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .stroke(T.border, lineWidth: 1)
                                )
                                .foregroundStyle(T.core.text)
                        }

                        // Type (stretched cards)
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Type") // was "Mode"
                                .font(.system(.subheadline, design: .rounded).weight(.semibold))

                            VStack(spacing: 14) {
                                ModeCard(
                                    T: T,
                                    mode: .dailyJournal,
                                    isSelected: selectedMode == .dailyJournal,
                                    disabled: false
                                ) { selectedMode = .dailyJournal }

                                ModeCard(
                                    T: T,
                                    mode: .collections,
                                    isSelected: selectedMode == .collections,
                                    disabled: !entitlements.isPro,
                                    comingSoonTag: entitlements.isPro ? nil : "PRO"
                                ) {
                                    if entitlements.isPro {
                                        selectedMode = .collections
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 24) // breathing room above bottom bar
                }

                // Bottom button bar (no safeAreaInset)
                Divider()
                  .frame(height: 0.6)
                  .background(T.core.text.opacity(0.15))

                HStack {
                    Button(action: createProject) {
                        HStack(spacing: 10) {
                            Ph.plusCircle.fill
                                .color(.white)
                                .frame(width: 20, height: 20)

                            Text("Create Project")
                                .font(.system(.headline, design: .rounded))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .disabled(nameTrimmed.isEmpty)
                    .foregroundStyle(.white)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(nameTrimmed.isEmpty ? T.core.accent.opacity(0.5) : T.core.accent)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(T.border, lineWidth: 1)
                    )
                    .shadow(color: T.core.accent.opacity(0.22), radius: 8, y: 4)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(
                    ZStack {
                        T.core.surface
                        Divider()
                            .frame(maxHeight: .infinity, alignment: .top)
                            .background(T.core.text.opacity(0.12))
                    }
                )
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])                // sheet at full height
        .presentationDragIndicator(.visible)
        .scrollDismissesKeyboard(.interactively)
        .background(T.core.surface)     // matches CalendarView background
        .alert("One journal on Free",
          isPresented: $showLimitAlert,
          actions: {
              Button("OK", role: .cancel) {}
          },
          message: {
              Text("Upgrade to Pro to create more journals.")
          })
    }


    private var nameTrimmed: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func createProject() {
        let trimmed = nameTrimmed
        guard !trimmed.isEmpty else { return }

        do {
            // (7) Use the guarded API with project type
            let proj = try store.createProject(name: trimmed, entitlements: entitlements, type: selectedMode.projectType)

            // Save the mode for overlay badges
            let key = "project.mode.\(proj.id)"
            UserDefaults.standard.set(selectedMode.rawValue, forKey: key)

            // Track project creation for review prompt
            ReviewManager.shared.recordProjectCreation()

            // Navigate immediately
            onCreateID?(proj.id)
            dismiss()

        } catch JournalCreationError.limitReached {
            // Should rarely hit because of the UI gate, but safe to handle
            showLimitAlert = true
        } catch {
            // You can log or present a generic error here if you like
            showLimitAlert = true
        }
    }



}

private struct ModeCard: View {
    let T: Theme
    @Environment(\.colorScheme) private var scheme
    let mode: NewProjectSheet.ProjectMode
    let isSelected: Bool
    let disabled: Bool
    var comingSoonTag: String? = nil
    let onTap: () -> Void

    @ViewBuilder
    private var leadingIcon: some View {
        switch mode {
        case .dailyJournal:
            Ph.calendarBlank.regular
                .color(T.core.accent)
        case .timelapse:
            Ph.filmStrip.regular
                .color(T.core.accent)
        case .collections:
            Ph.squaresFour.regular
                .color(T.core.accent)
        }
    }

    var body: some View {
        Button(action: { if !disabled { onTap() } }) {
            HStack(alignment: .top, spacing: 12) {
                leadingIcon
                    .frame(width: 22, height: 22)

                VStack(alignment: .leading, spacing: 4) {
                    Text(mode.rawValue)
                        .font(.system(.headline, design: .rounded))
                        .foregroundStyle(T.core.text)

                    Text(mode.subtitle)
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(T.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                (isSelected ? Ph.checkCircle.fill : Ph.circle.regular)
                    .color(isSelected ? T.core.accent : T.textSecondary.opacity(0.7))
                    .frame(width: 22, height: 22)
                    .opacity(disabled ? 0.4 : 1.0)
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 72)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        scheme == .dark
                        ? T.core.surface.opacity(isSelected ? 0.95 : 0.85)
                        : .white.opacity(isSelected ? 0.97 : 0.94)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(
                        isSelected ? T.core.accent : T.border,
                        lineWidth: isSelected ? 2 : 1
                    )
            )
            .shadow(
                color: scheme == .dark ? .black.opacity(0.6) : .black.opacity(0.08),
                radius: 8,
                y: 4
            )
            .overlay(alignment: .topTrailing) {
                if let tag = comingSoonTag, disabled {
                    Text(tag)
                        .font(.system(.caption2, design: .rounded).weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(T.core.text.opacity(0.08))
                        .clipShape(Capsule())
                        .padding(10)
                }
            }
            .opacity(disabled ? 0.55 : 1.0)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}
