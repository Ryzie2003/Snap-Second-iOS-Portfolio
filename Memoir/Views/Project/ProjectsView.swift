import SwiftUI
import UIKit
import PhosphorSwift
import RevenueCat
import RevenueCatUI
import RiveRuntime

struct ProjectsView: View {
    @EnvironmentObject var onboarding: OnboardState
    @EnvironmentObject private var store: ProjectStore
    @EnvironmentObject private var homeRouter: HomeRouter
    @EnvironmentObject private var entitlements: Entitlements

    @ObservedObject private var clipStore = ClipStore.shared
    @ObservedObject var projectStore: ProjectStore

    @State private var showSheet      = false
    @State private var editMode       : EditMode = .inactive
    @State private var selection      = Set<Project.ID>()
    @State private var confirmDelete  = false
    @State private var projectToOpen: Project?
    @State private var navPath = NavigationPath()
    @State private var showCreateSheet = false
    @State private var showProUpsell = false

    @State private var freezeOnce = false
    @State private var projectToWatch: Project? = nil

    @State private var currentIndex: Int = 0
    @State private var scrolledToLastProject = false

    @Environment(\.colorScheme) private var scheme
    private var T: Theme { AppTheme.sunsetGlow.theme(for: scheme) }

    // MARK: - Responsive layout

    /// Decide the layout scale *once* per view using screen height.
    private var layoutScale: LayoutScale {
        LayoutScale.forScreenHeight()
    }


    @EnvironmentObject private var paywall: PaywallCoordinator
    func presentPaywall() { paywall.present() }

    @State private var shouldOpenPaywallAfterUpsell = false

    var body: some View {
        ZStack {
            // Brand surface behind everything
            T.core.surface
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Top title + New button uses responsive padding
                headerSection
                    .padding(.horizontal, layoutScale.headerHorizontalPadding)
                    .padding(.top, layoutScale.headerTopPadding)

                if store.projects.isEmpty {
                    Spacer()
                    EmptyProjectsHint(
                        T: T,
                        addAction: { showSheet = true }
                    )
                    .padding(.horizontal, 24)
                    .padding(.vertical, 24)
                    Spacer()
                } else {
                    GeometryReader { geo in
                        let projects = store.projects
                        let availableHeight = geo.size.height

                        // Base height from layout scale
                        let baseCardHeight = availableHeight * layoutScale.cardHeightFactor
                        let cardWidthFromHeight = baseCardHeight * 9.0 / 16.0

                        // Constrain by width so cards don't get tiny/huge on small/large screens
                        let maxCardWidth = geo.size.width * layoutScale.maxCardWidthFraction
                        let finalCardWidth = min(cardWidthFromHeight, maxCardWidth)
                        let finalCardHeight = finalCardWidth * 16.0 / 9.0

                        // Padding so the first/last card can center
                        let sidePadding = max((geo.size.width - finalCardWidth) / 2.0, 0)

                        let vStackSpacing: CGFloat = 16 * layoutScale.spacingScale
                        let hStackSpacing: CGFloat = 16 * layoutScale.spacingScale

                        VStack(spacing: vStackSpacing) {
                            // MAIN CAROUSEL: horizontal paging with real cards peeking
                            ScrollViewReader { proxy in
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: hStackSpacing) {
                                        ForEach(projects) { project in
                                            ProjectCarouselCard(
                                                project: project,
                                                T: T,
                                                onOpen: {
                                                    let timer = PerfTimer("OpenJournal \(project.name)")
                                                    UserDefaults.standard.set(
                                                        project.id.uuidString,
                                                        forKey: "lastOpenedProjectID"
                                                    )
                                                    // Route based on project type
                                                    switch project.type {
                                                    case .dailyJournal, .timelapse:
                                                        homeRouter.openCalendar(project.id)
                                                    case .collections:
                                                        homeRouter.openCollections(project.id)
                                                    }
                                                    timer.end()
                                                },
                                                onWatch: {
                                                    projectToWatch = project
                                                },
                                                onRename: { newName in
                                                    let trimmed = newName.trimmingCharacters(
                                                        in: .whitespacesAndNewlines
                                                    )
                                                    guard !trimmed.isEmpty else { return }
                                                    store.rename(id: project.id, to: trimmed)
                                                },
                                                onDelete: {
                                                    deleteOne(project.id)
                                                }
                                            )
                                            .frame(width: finalCardWidth, height: finalCardHeight)
                                            .id(project.id) // Add ID for ScrollViewReader
                                            // Center card = full size; neighbors = slightly smaller + dimmer
                                            .scrollTransition(.interactive, axis: .horizontal) { view, phase in
                                                view
                                                    .scaleEffect(phase.isIdentity ? 1.0 : 0.88)
                                                    .opacity(phase.isIdentity ? 1.0 : 0.55)
                                            }
                                        }
                                    }
                                    .scrollTargetLayout()
                                    .safeAreaPadding(.horizontal, sidePadding)
                                    .frame(height: finalCardHeight)
                                }
                                // Snap to each card as a page
                                .scrollTargetBehavior(.viewAligned)
                                .frame(height: finalCardHeight)
                                .onAppear {
                                    // Scroll to last opened project when view appears
                                    if !scrolledToLastProject,
                                       let savedID = UserDefaults.standard.string(forKey: "lastOpenedProjectID"),
                                       let projectID = UUID(uuidString: savedID),
                                       projects.contains(where: { $0.id == projectID }) {

                                        // Scroll to the saved project
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                            withAnimation(.easeInOut(duration: 0.3)) {
                                                proxy.scrollTo(projectID, anchor: .center)
                                            }
                                            scrolledToLastProject = true
                                        }
                                    }
                                }
                            }
                        }
                        .frame(width: geo.size.width, height: availableHeight, alignment: .center)
                    }
                    .padding(.top, 16 * layoutScale.spacingScale)
                    .padding(.bottom, 24 * layoutScale.spacingScale)
                }
            }
        }
        // ===== existing modifiers below stay the same =====
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarHidden(true)
        .alert("Delete selected projects?",
               isPresented: $confirmDelete,
               actions: deleteAlertButtons)
        .sheet(isPresented: $showSheet) {
            NewProjectSheet(T:T, onCreateID: { createdID in
                // Get the project to determine its type
                if let project = store.projects.first(where: { $0.id == createdID }) {
                    DispatchQueue.main.async {
                        switch project.type {
                        case .dailyJournal, .timelapse:
                            homeRouter.openCalendar(createdID)
                        case .collections:
                            homeRouter.openCollections(createdID)
                        }
                    }
                }
            })
            .environmentObject(store)
        }
        .sheet(
            isPresented: $showProUpsell,
            onDismiss: {
                // Only fire the paywall if the upsell explicitly requested it
                if shouldOpenPaywallAfterUpsell {
                    presentPaywall()
                    shouldOpenPaywallAfterUpsell = false
                }
            }
        ) {
            ProProjectsUpsellSheet(T: T) {
                // 1) Mark that we want the paywall once the sheet closes
                shouldOpenPaywallAfterUpsell = true

                // 2) Dismiss the upsell by toggling the binding from the parent
                showProUpsell = false
            }
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
        .fullScreenCover(item: $projectToWatch) { project in
            MontageView(project: project, T: T)
        }
        .environment(\.editMode, $editMode)
        .onChange(of: editMode) { if !$0.isEditing { selection.removeAll() } }
        .background(T.core.surface)
        .onAppear {
            guard !freezeOnce else { return }
            freezeOnce = true
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) { }
            DispatchQueue.main.async { freezeOnce = false }

            // Reset scroll flag when view appears so it can scroll to last project
            scrolledToLastProject = false
        }
        .animation(nil, value: clipStore.countByProject)
    }


    private func deleteOne(_ id: Project.ID) {
        store.delete(ids: [id])
    }

    private var headerSection: some View {
        // Base sizes that we scale per device
        let baseTitleSize: CGFloat      = 34
        let baseButtonFontSize: CGFloat = 15
        let baseSubtitleFont: Font = .system(.caption2, design: .rounded)

        let titleSize   = baseTitleSize * layoutScale.fontScale
        let buttonSize  = baseButtonFontSize * layoutScale.fontScale
        let vSpacing    = 12 * layoutScale.spacingScale
        let hSpacing: CGFloat = 12 * layoutScale.spacingScale

        return VStack(alignment: .leading, spacing: vSpacing) {
            // Top row: Title + action
            HStack(alignment: .center, spacing: hSpacing) {
                Text("Projects")
                    .font(.system(size: titleSize, weight: .heavy, design: .rounded))
                    .foregroundStyle(T.core.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    if !entitlements.isPro && store.projects.count >= 1 {
                        // Non-Pro user trying to create another project → show upsell screen
                        showProUpsell = true
                    } else {
                        // Pro users or first project → go straight to creation
                        showSheet = true
                    }
                } label: {
                    HStack(spacing: 6) {
                        Ph.plusCircle.fill
                            .color(.white)
                            .frame(width: 18, height: 18)
                        Text("New Project")
                    }
                    .font(.system(size: buttonSize, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 6 * layoutScale.spacingScale)
                    .padding(.vertical, 4 * layoutScale.spacingScale)
                }
                .padding(.top, 8 * layoutScale.spacingScale)
                .buttonStyle(.borderedProminent)
                .tint(T.core.accent)
                .controlSize(.regular)
            }
            // Subtitle copy: full width under the row
            Text("All your projects in one place — add new ones and pick up where you left off.")
                .font(.system(
                    size: UIFont.preferredFont(forTextStyle: .callout).pointSize * layoutScale.subtitleScale,
                    design: .rounded
                ))
                .foregroundStyle(T.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .minimumScaleFactor(0.7)
        }
    }




    // MARK: - Trash behavior
    private func handleTrashTapped() {
        if !editMode.isEditing {
            // Enter selection mode
            editMode = .active
        } else {
            // Already editing: if something is selected, confirm delete; otherwise exit edit mode
            if selection.isEmpty {
                editMode = .inactive
            } else {
                confirmDelete = true
            }
        }
    }

    // MARK: - Selection toggle
    private func toggleSelection(_ id: Project.ID) {
        if selection.contains(id) { selection.remove(id) }
        else                      { selection.insert(id) }
    }

    private func deleteAlertButtons() -> some View {
        Group {
            Button("Delete", role: .destructive) {
                store.delete(ids: selection)
                selection.removeAll()
                editMode = .inactive
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}


private struct ProjectCarouselCard: View {
    let project: Project
    let T: Theme
    let onOpen: () -> Void        // tap card to open calendar/journal
    let onWatch: () -> Void       // play montage
    let onRename: (String) -> Void // commit rename back to store
    let onDelete: () -> Void      // delete project

    @Environment(\.colorScheme) private var scheme
    @ObservedObject private var clipStore = ClipStore.shared

    private var clipCount: Int {
        clipStore.countByProject[project.id] ?? 0
    }

    private var projectTypeLabel: String {
        let key = "project.mode.\(project.id)"
        return UserDefaults.standard.string(forKey: key) ?? "Daily Journal"
    }

    private var thumbData: Data? {
        clipStore.latestThumbData(for: project)
    }

    private var thumbKey: String {
        "project-\(project.id.uuidString)"
    }

    enum CoverStyle: String, CaseIterable {
        case brown, navy, forest, burgundy, charcoal

        var gradient: [Color] {
            switch self {
            case .brown:
                return [
                    Color(red: 0.38, green: 0.26, blue: 0.18),
                    Color(red: 0.18, green: 0.11, blue: 0.08)
                ]
            case .navy:
                return [
                    Color(red: 0.14, green: 0.18, blue: 0.30),
                    Color(red: 0.07, green: 0.10, blue: 0.18)
                ]
            case .forest:
                return [
                    Color(red: 0.16, green: 0.28, blue: 0.20),
                    Color(red: 0.07, green: 0.16, blue: 0.11)
                ]
            case .burgundy:
                return [
                    Color(red: 0.36, green: 0.12, blue: 0.16),
                    Color(red: 0.18, green: 0.05, blue: 0.08)
                ]
            case .charcoal:
                return [
                    Color(red: 0.22, green: 0.22, blue: 0.24),
                    Color(red: 0.10, green: 0.10, blue: 0.12)
                ]
            }
        }

        var title: String {
            rawValue.capitalized
        }
    }

    @State private var showCoverPicker = false
    @State private var coverStyle: CoverStyle

    @State private var isEditingName = false
    @State private var editableName: String
    @FocusState private var nameFieldFocused: Bool

    // Custom init so we can seed coverStyle + editableName from project
    init(
        project: Project,
        T: Theme,
        onOpen: @escaping () -> Void,
        onWatch: @escaping () -> Void,
        onRename: @escaping (String) -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.project = project
        self.T = T
        self.onOpen = onOpen
        self.onWatch = onWatch
        self.onRename = onRename
        self.onDelete = onDelete

        let key = "project.cover.\(project.id)"
        if let raw = UserDefaults.standard.string(forKey: key),
           let style = CoverStyle(rawValue: raw) {
            _coverStyle = State(initialValue: style)
        } else {
            _coverStyle = State(initialValue: .brown)
        }

        _editableName = State(initialValue: project.name)
        _isEditingName = State(initialValue: false)
    }

    private func setCover(_ style: CoverStyle) {
        coverStyle = style
        let key = "project.cover.\(project.id)"
        UserDefaults.standard.set(style.rawValue, forKey: key)
    }

    private func commitRename() {
        let trimmed = editableName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            // reset and exit if user clears everything
            editableName = project.name
            withAnimation { isEditingName = false }
            nameFieldFocused = false
            return
        }
        onRename(trimmed)
        withAnimation { isEditingName = false }
        nameFieldFocused = false
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size

            ZStack {
                // MARK: Leather "book cover" base
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: coverStyle.gradient,
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .stroke(Color.black.opacity(0.25), lineWidth: 1.0)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .stroke(Color.white.opacity(0.14), lineWidth: 0.6)
                            .blur(radius: 0.5)
                            .opacity(0.8)
                    )

                // Soft vignette
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(
                        RadialGradient(
                            colors: [
                                Color.black.opacity(0.35),
                                Color.clear
                            ],
                            center: .center,
                            startRadius: min(size.width, size.height) * 0.05,
                            endRadius: min(size.width, size.height) * 0.65
                        )
                    )
                    .blendMode(.multiply)
                    .allowsHitTesting(false)

                // Vertical spine line
                RoundedRectangle(cornerRadius: 1)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.black.opacity(0.35),
                                Color.white.opacity(0.12),
                                Color.black.opacity(0.35)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 2)
                    .frame(maxHeight: .infinity, alignment: .center)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 28)
                    .allowsHitTesting(false)

                // MARK: Content overlay
                VStack(spacing: 0) {
                    HStack {
                        Spacer()

                        Menu {
                            Button {
                                onWatch()
                            } label: {
                                HStack(spacing: 10) {
                                    Ph.play.regular
                                        .color(.primary)
                                        .frame(width: 16, height: 16)
                                    Text("Play Montage")
                                }
                            }

                            Button {
                                showCoverPicker = true
                            } label: {
                                HStack(spacing: 10) {
                                    Ph.paintBucket.regular
                                        .color(.primary)
                                        .frame(width: 16, height: 16)
                                    Text("Change Journal Color")
                                }
                            }

                            Button {
                                editableName = project.name
                                withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                                    isEditingName = true
                                }
                                DispatchQueue.main.async {
                                    nameFieldFocused = true
                                }
                            } label: {
                                HStack(spacing: 10) {
                                    Ph.pencilSimple.regular
                                        .color(.primary)
                                        .frame(width: 16, height: 16)
                                    Text("Edit Project Name")
                                }
                            }

                            Button(role: .destructive) {
                                onDelete()
                            } label: {
                                HStack(spacing: 10) {
                                    Ph.trash.regular
                                        .color(.red)
                                        .frame(width: 16, height: 16)
                                    Text("Delete")
                                }
                            }
                        } label: {
                            Ph.dotsThree.bold
                                .color(.white.opacity(0.9))
                                .frame(width: 24, height: 24)
                                .frame(width: 48, height: 48)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 6)

                    Spacer(minLength: 10)

                    // Thumbnail / fallback panel
                    if let data = thumbData {
                        AsyncThumbImage(
                            data: data,
                            key: thumbKey
                        )
                        .aspectRatio(16/9, contentMode: .fill)
                        .frame(
                            width: size.width * 0.80,
                            height: size.height * 0.42
                        )
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(Color.white.opacity(0.55), lineWidth: 0.8)
                        )
                        .shadow(radius: 6, y: 4)
                        .padding(.horizontal, 8)
                        .padding(.top, 4)
                    } else {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: coverStyle.gradient,
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .overlay(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.05),
                                        Color.clear,
                                        Color.black.opacity(0.15)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .stroke(Color.white.opacity(0.25), lineWidth: 0.7)
                            )
                            .overlay {
                                Ph.sparkle.regular
                                    .color(.white.opacity(0.75))
                                    .frame(width: 22, height: 22)
                            }
                            .frame(
                                width: size.width * 0.78,
                                height: size.height * 0.40
                            )
                            .padding(.horizontal, 10)
                            .padding(.top, 6)
                    }

                    Spacer(minLength: 8)

                    VStack(spacing: 8) {
                        // Inline editable title
                        if isEditingName {
                            ZStack {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color.white.opacity(0.12))

                                TextField("", text: $editableName, onCommit: {
                                    commitRename()
                                })
                                .font(.system(size: 22, weight: .bold, design: .serif))
                                .foregroundColor(.white)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .focused($nameFieldFocused)
                                .submitLabel(.done)
                            }
                            .padding(.horizontal, 16)
                            .transition(.opacity.combined(with: .scale))
                        } else {
                            Text(project.name)
                                .font(.system(size: 22, weight: .bold, design: .serif))
                                .foregroundColor(Color.white.opacity(0.96))
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                                .minimumScaleFactor(0.8)
                                .padding(.horizontal, 16)
                        }

                        HStack(spacing: 6) {
                            Ph.filmStrip.regular
                                .color(.white.opacity(0.85))
                                .frame(width: 14, height: 14)

                            Text("\(clipCount) clip\(clipCount == 1 ? "" : "s")")
                            Text("•")
                            Text(projectTypeLabel)
                        }
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.80))
                        .padding(.horizontal, 16)
                    }
                    .padding(.bottom, 80)
                }
                .frame(width: size.width, height: size.height)
            }
            .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .onTapGesture {
                // If editing, tapping outside just commits; otherwise, open project
                if isEditingName {
                    commitRename()
                } else {
                    onOpen()
                }
            }
        }
        .sheet(isPresented: $showCoverPicker) {
            ZStack {
                // Brand background
                T.core.surface
                    .ignoresSafeArea()

                VStack(spacing: 20) {
                    // Drag handle
                    Capsule()
                        .fill(T.core.text.opacity(0.15))
                        .frame(width: 40, height: 4)
                        .padding(.top, 8)

                    // Header
                    VStack(spacing: 6) {
                        HStack(spacing: 8) {
                            Ph.bookBookmark.regular
                                .color(T.core.accent)
                                .frame(width: 20, height: 20)

                            Text("Journal Color")
                                .font(.system(size: 20, weight: .semibold, design: .rounded))
                                .foregroundStyle(T.core.text)
                        }
                    }
                    .padding(.top, 4)

                    // Swatch grid
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: 3),
                        spacing: 18
                    ) {
                        ForEach(CoverStyle.allCases, id: \.self) { style in
                            Button {
                                setCover(style)
                                showCoverPicker = false
                            } label: {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .fill(
                                            LinearGradient(
                                                colors: style.gradient,
                                                startPoint: .top,
                                                endPoint: .bottom
                                            )
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                                .stroke(
                                                    style == coverStyle
                                                    ? T.core.accent
                                                    : T.border.opacity(0.8),
                                                    lineWidth: style == coverStyle ? 2 : 1
                                                )
                                        )
                                        .shadow(
                                            color: .black.opacity(0.16),
                                            radius: 6, y: 3
                                        )

                                    VStack(spacing: 4) {
                                        Text(style.title)
                                            .font(.system(.caption, design: .rounded).weight(.semibold))
                                            .foregroundStyle(.white)

                                        if style == coverStyle {
                                            HStack(spacing: 4) {
                                                Ph.checkCircle.fill
                                                    .color(.white)
                                                    .frame(width: 14, height: 14)
                                                Text("Selected")
                                                    .font(.system(.caption2, design: .rounded))
                                                    .foregroundStyle(.white.opacity(0.9))
                                            }
                                        }
                                    }
                                    .padding(.horizontal, 8)
                                }
                                .frame(height: 90)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 20)

                    Spacer(minLength: 8)
                }
                .padding(.bottom, 16)
            }
            .presentationDetents([.medium])
            .presentationDragIndicator(.hidden)
        }

    }
}



// Project rename sheet
private struct RenameSheet: View {
    let title: String
    let initial: String
    let T: Theme
    var onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        ZStack {
            // Brand background
            T.core.surface
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Drag handle
                Capsule()
                    .fill(T.core.text.opacity(0.15))
                    .frame(width: 40, height: 4)
                    .padding(.top, 8)
                    .padding(.bottom, 12)

                // Header
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Ph.pencilSimple.regular
                            .color(T.core.accent)
                            .frame(width: 20, height: 20)

                        Text(title)
                            .font(.system(size: 20, weight: .semibold, design: .rounded))
                            .foregroundStyle(T.core.text)
                    }

                    Text("Give this Project a name that fits the story you’re telling.")
                        .font(.system(.footnote, design: .rounded))
                        .foregroundStyle(T.core.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.bottom, 16)

                // Text field card
                VStack(alignment: .leading, spacing: 8) {
                    Text("Project name")
                        .font(.system(.caption, design: .rounded).weight(.semibold))
                        .foregroundStyle(T.core.text)

                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(
                                Color.white.opacity(0.95)
                                    .blendMode(.normal)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(T.border, lineWidth: 1)
                            )

                        TextField("My 2025", text: $name)
                            .textInputAutocapitalization(.words)
                            .autocorrectionDisabled()
                            .font(.system(.body, design: .rounded))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)

                Spacer(minLength: 12)

                // Bottom action bar
                HStack(spacing: 12) {
                    Button {
                        dismiss()
                    } label: {
                        Text("Cancel")
                            .font(.system(.body, design: .rounded))
                            .foregroundStyle(T.textSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(T.core.surface.opacity(0.9))
                            )
                    }

                    Button {
                        onSave(trimmedName)
                        dismiss()
                    } label: {
                        HStack(spacing: 8) {
                            Ph.checkCircle.fill
                                .color(.white)
                                .frame(width: 18, height: 18)
                            Text("Save")
                                .font(.system(.body, design: .rounded).weight(.semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(trimmedName.isEmpty ? T.core.accent.opacity(0.5) : T.core.accent)
                        )
                    }
                    .disabled(trimmedName.isEmpty)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .background(
                    ZStack {
                        T.core.surface
                        Divider()
                            .background(T.core.text.opacity(0.12))
                            .frame(maxHeight: .infinity, alignment: .top)
                    }
                )
            }
        }
        .onAppear { name = initial }
    }
}




struct FramePreferenceKey: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>],
                       nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

// 5) Add this tiny destination wrapper at the bottom of the file:
private struct CalendarDestination: View {
    @EnvironmentObject private var store: ProjectStore
    @EnvironmentObject private var clipStore: ClipStore
    let projectID: Project.ID

    var body: some View {
        if let proj = store.projects.first(where: { $0.id == projectID }) {
            CalendarView(project: proj)
                .id(proj.id)
                .environmentObject(clipStore)
        } else {
            // Fallback UI if the project can’t be found for any reason
            Text("Project not found").font(.headline).padding()
        }
    }
}

// Add this helper view to the bottom of ProjectsView.swift (below your other private views)

private struct EmptyProjectsHint: View {
    let T: Theme
    var addAction: () -> Void

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 14) {
                Text("Create your first Snap Second project to start capturing moments and build your montage.")
                    .font(.callout)
                    .foregroundStyle(T.textSecondary)
                    .multilineTextAlignment(.center)
                    .opacity(0.7)

                Button(action: {
                    addAction()   // parent decides whether to gate or show the create sheet
                }) {
                    HStack(spacing: 6) {
                        Ph.plus.regular
                            .color(.white)
                            .frame(width: 16, height: 16)
                        Text("New Project")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(T.core.accent)
                .padding(.top, 6)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .frame(height: max(proxy.size.height * 0.66, 320))
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
            .padding(.horizontal, 8)
        }
        .frame(height: 420)
    }
}

private struct ProProjectsUpsellSheet: View {
    let T: Theme
    var onUpgrade: () -> Void

    @Environment(\.dismiss) private var dismiss

    // Responsive layout
    private var layoutScale: LayoutScale { LayoutScale.forScreenHeight() }

    // Scaled values for smaller screens
    private var titleSize: CGFloat {
        switch layoutScale {
        case .small:  return 18
        case .medium: return 20
        case .large:  return 22
        }
    }

    private var iconSize: CGFloat {
        switch layoutScale {
        case .small:  return 18
        case .medium: return 20
        case .large:  return 22
        }
    }

    private var circleSize: CGFloat {
        switch layoutScale {
        case .small:  return 40
        case .medium: return 44
        case .large:  return 48
        }
    }

    private var sectionSpacing: CGFloat {
        switch layoutScale {
        case .small:  return 10
        case .medium: return 14
        case .large:  return 16
        }
    }

    private var horizontalPadding: CGFloat {
        switch layoutScale {
        case .small:  return 16
        case .medium: return 18
        case .large:  return 20
        }
    }

    var body: some View {
        ZStack {
            T.core.surface
                .ignoresSafeArea()

            VStack(spacing: 0) {

                // Drag handle
                Capsule()
                    .fill(T.core.text.opacity(0.15))
                    .frame(width: 40, height: 4)
                    .padding(.top, 8)
                    .padding(.bottom, layoutScale == .small ? 8 : 12)

                // ===== TOP TITLE (centered) =====
                VStack(spacing: layoutScale == .small ? 8 : 12) {
                    ZStack {
                        Circle()
                            .fill(T.core.accent.opacity(0.18))
                            .frame(width: circleSize, height: circleSize)

                        Ph.bookBookmark.fill
                            .color(T.core.accent)
                            .frame(width: iconSize, height: iconSize)
                    }

                    Text("Upgrade for Unlimited Projects")
                        .font(.system(size: titleSize, weight: .bold, design: .rounded))
                        .foregroundStyle(T.core.text)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.75)
                }
                .padding(.horizontal, horizontalPadding)



                // ===== PROJECT TYPES SECTION (left-aligned) =====
                VStack(alignment: .leading, spacing: sectionSpacing) {

                    // Daily Journal
                    HStack(alignment: .top, spacing: 10) {

                        // Icon (mirrors ModeCard style)
                        Ph.calendarBlank.regular
                            .color(T.core.accent)
                            .frame(width: iconSize, height: iconSize)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Daily Journal")
                                .font(.system(size: layoutScale == .small ? 14 : 16, weight: .semibold, design: .rounded))
                                .foregroundStyle(T.core.text)

                            Text("Capture short moments each day — simple, low-pressure entries that build into a meaningful movie over time.")
                                .font(.system(size: layoutScale == .small ? 11 : 12, design: .rounded))
                                .foregroundStyle(T.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer()
                    }

                    // Collections
                    HStack(alignment: .top, spacing: 10) {

                        // Icon (mirrors ModeCard style)
                        Ph.squaresFour.regular
                            .color(T.core.accent)
                            .frame(width: iconSize, height: iconSize)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Collections")
                                .font(.system(size: layoutScale == .small ? 14 : 16, weight: .semibold, design: .rounded))
                                .foregroundStyle(T.core.text)

                            Text("Organize any clips you want—no timeline required.")
                                .font(.system(size: layoutScale == .small ? 11 : 12, design: .rounded))
                                .foregroundStyle(T.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer()
                    }
                }
                .padding(.top, layoutScale == .small ? 14 : 20)
                .padding(.horizontal, horizontalPadding)

                Spacer(minLength: 8)

                // ===== CTA SECTION =====
                VStack(spacing: layoutScale == .small ? 6 : 10) {

                    Button {
                        onUpgrade()   // parent (ProjectsView) will flip flags & handle paywall
                    } label: {
                        HStack(spacing: 6) {
                            Ph.sparkle.fill
                                .color(.white)
                                .frame(width: 16, height: 16)

                            Text("Upgrade to Pro")
                                .font(.system(size: layoutScale == .small ? 15 : 17, weight: .semibold, design: .rounded))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, layoutScale == .small ? 12 : 14)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(T.core.accent)
                        )
                        .foregroundStyle(.white)
                    }

                    Button {
                        dismiss()
                    } label: {
                        Text("Maybe later")
                            .font(.system(size: layoutScale == .small ? 14 : 16, design: .rounded))
                            .foregroundStyle(T.textSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, layoutScale == .small ? 6 : 10)
                    }
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.bottom, layoutScale == .small ? 12 : 16)
            }
        }
    }
}
