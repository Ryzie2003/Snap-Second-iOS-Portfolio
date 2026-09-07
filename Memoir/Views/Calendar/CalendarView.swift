import SwiftUI
import AVFoundation
import Photos
import Combine
import UIKit
import PhosphorSwift

enum ProjectViewMode: String, CaseIterable, Identifiable {
    case calendar, timeline
    var id: String { rawValue }
}

private struct ClipLocalID: Identifiable, Hashable {
    let localID: String         // PHAsset.localIdentifier
    let id = UUID()             // unique identity per presentation
}

// 4-color core
struct ThemeCore {
    let primary: Color   // cool: selection, today ring, links
    let accent:  Color   // warm: add/celebrate, "today" (if you prefer)
    let surface: Color   // page/card background (we keep page = white)
    let text:    Color   // ink
}

struct Theme {
    let core: ThemeCore
    // Derived tokens (no new hues)
    var primaryMuted: Color   { core.primary.opacity(0.14) }
    var primaryPressed: Color { core.primary.darken(0.14) }
    var border: Color         { core.text.opacity(0.15) }
    var surfaceAlt: Color     { core.surface.mix(with: core.primary, amount: 0.06) }
    var textSecondary: Color  { core.text.opacity(0.65) }
}

// Tiny color math (UIKit bridge)
extension Color {
    func darken(_ amount: CGFloat) -> Color { adjust(brightness: -amount) }

    func mix(with other: Color, amount: CGFloat) -> Color {
        let a = UIColor(self), b = UIColor(other)
        var r: CGFloat=0, g: CGFloat=0, bl: CGFloat=0, a1: CGFloat=0
        var r2: CGFloat=0, g2: CGFloat=0, bl2: CGFloat=0, a2: CGFloat=0
        guard a.getRed(&r, green: &g, blue: &bl, alpha: &a1),
              b.getRed(&r2, green: &g2, blue: &bl2, alpha: &a2) else { return self }
        let t = max(0, min(1, amount))
        return Color(
            red:     Double(r  * (1 - t) + r2  * t),
            green:   Double(g  * (1 - t) + g2  * t),
            blue:    Double(bl * (1 - t) + bl2 * t),
            opacity: Double(a1 * (1 - t) + a2 * t)
        )
    }

    private func adjust(brightness: CGFloat) -> Color {
        let u = UIColor(self)
        var h: CGFloat=0, s: CGFloat=0, b: CGFloat=0, a: CGFloat=0
        guard u.getHue(&h, saturation: &s, brightness: &b, alpha: &a) else { return self }
        return Color(hue: Double(h), saturation: Double(s), brightness: Double(max(0,min(1,b+brightness))), opacity: Double(a))
    }
}


// Recommended palettes (light-mode)
enum AppTheme: String, CaseIterable, Identifiable {
    case sunsetGlow        // blue + apricot (trust + fun)


    var id: String { rawValue }

    var theme: Theme {
        switch self {
        case .sunsetGlow:
            return Theme(core: .init(
                primary: Color(hex:"#3F88C5"),   // Lake Blue (selection, links)
                accent:  Color(hex:"#FF6347"),   // Apricot (today/CTA)
                surface: Color(hex:"#F9F5F0"),   // Linen white
                text:    Color(hex:"#1A1A22")    // Ink
            ))
        }
    }
}

// Build a Theme for the current appearance (light/dark), no assets needed.
extension AppTheme {
    func theme(for scheme: ColorScheme) -> Theme {
        switch self {
        case .sunsetGlow:
            if scheme == .dark {
                // ---- DARK SET
                return Theme(core: .init(
                    primary: Color(hex:"#3F88C5"),   // keep brand
                    accent:  Color(hex:"#FF6B54"),   // tiny lift so it pops on dark
                    surface: Color(hex:"#1B212B"),   // page/card background on dark
                    text:    Color(hex:"#EAEAF0")    // primary text on dark
                ))
            } else {
                // ---- LIGHT SET (your current)
                return Theme(core: .init(
                    primary: Color(hex:"#3F88C5"),
                    accent:  Color(hex:"#FF6347"),
                    surface: Color(hex:"#F9F5F0"),
                    text:    Color(hex:"#1A1A22")
                ))
            }
        }
    }
}





// MARK: – CalendarView
// Supporting files:
// - CalendarHelpers.swift: UI components (SmartFillToast, QuickIconButton, etc.)
// - CalendarTheme.swift: Layout scale extensions
// - CalendarViewModel.swift: SmartFillVM and state management

struct CalendarView: View {
    // ─── Model
    let project: Project

    @Environment(\.dismiss) private var dismiss

    // Onboarding
    @EnvironmentObject private var onboard: OnboardState
    @State private var showCalendarTip = false

    // ─── Environment & stores
    @EnvironmentObject private var store: ClipStore
    @EnvironmentObject private var launchSnapshots: CalendarLaunchSnapshotStore

    // ─── UI state
    @State private var showLibraryPicker   = false
    @State private var showCapture         = false
    private var hairline: CGFloat { 0 / UIScreen.main.scale }

    // Smart Fill
    @State private var showSmartFillSheet  = false
    @State private var smartFillRange      = Date() ... Date()
    @StateObject private var fillVM        = CalendarSmartFillVM()
    @State private var askToKeep           = false
    // MARK: – Quick bar & toast spacing
    private let quickBarEstimatedHeight: CGFloat = 64    // circle buttons + shadows
    private let quickBarBottomPadding: CGFloat  = 32     // your existing .padding(.bottom)
    private var toastBottomLift: CGFloat {
        quickBarEstimatedHeight + quickBarBottomPadding + 12
    }

    @Environment(\.colorScheme) private var scheme

    @State private var theme: AppTheme = .sunsetGlow
    private var T: Theme { theme.theme(for: scheme) }

    private var layoutScale: LayoutScale {
        LayoutScale.forScreenHeight()
    }

    @State private var showPlusMenu = false

    @State private var selectedDate: SelectedDate? = nil
    @State private var isNavigatingToDay = false  // Guard against navigation re-trigger loop
    @State private var currentMonth                = Date()      // today

    // Montage preview
    @State private var showMontage                 = false

    @State private var capturedImage    : UIImage? = nil
    @State private var capturedVideoURL : URL?     = nil

    @State private var isEditing      = false          // toggled by Edit button
    @State private var selection      = Set<Date>()    // day-level selection

    private var hasSelection: Bool { !selection.isEmpty }
    private var isPro: Bool { false }


    @State private var showReadyToast = false

    // Editor queue from LibraryPicker (edit mode)
    @State private var editQueue: [String] = []
    @State private var pendingLocalID: ClipLocalID?

    @State private var launchEditorAfterPickerDismiss = false
    @StateObject private var monthPresence = MonthAssetPresenceCache()

    private struct URLItem: Identifiable { let url: URL; var id: String { url.absoluteString } }

    @State private var capturedURLBuffer: URLItem? = nil
    @State private var pendingCapturedURL: URLItem? = nil
    @State private var launchEditorAfterCaptureDismiss = false
    // 1) STATE – add this near other @State vars
    @State private var confirmDeleteDay: Date? = nil
    // Already have: @State private var confirmDeleteDay: Date? = nil
    @State private var storePulse = 0

    private var isConfirmingDelete: Binding<Bool> {
        Binding(
            get: { confirmDeleteDay != nil },
            set: { if !$0 { confirmDeleteDay = nil } }
        )
    }

    @State private var didInitMonths = false
    @State private var topID: Date? = nil
    @State private var lockScrollPosition = false
    @State private var selectedStyle: MontageStyle = .classic


    @Environment(\.horizontalSizeClass) private var hSizeClass

    @State private var dayAssetBadgeCache: [Date: DayEmptyBadge?] = [:]


    // Progressive month loading (refined)
       @State private var visibleMonths: [Date] = []
       @State private var earliestAvailableMonth: Date = Date()
       @State private var isLoadingMore = false

       // MARK: - Month Management

    private var currentMonthStart: Date { startOfMonth(Date()) }

        private func startOfMonth(_ date: Date) -> Date {
            let cal = Calendar.current
            let comps = cal.dateComponents([.year, .month], from: date)
            return cal.date(from: comps)!
        }

    private func lastMonths(_ n: Int, endingAt end: Date) -> [Date] {
        let cal = Calendar.current
        var out: [Date] = []
        var m = end
        for _ in 0..<n {
            out.append(m)
            m = cal.date(byAdding: .month, value: -1, to: m)!
        }
        return out
    }

    private func computeEarliestAvailableMonth() -> Date {
        // Allow “infinite” scrolling backwards by setting an extremely early floor.
        // We still normalize to the first of that month so comparisons stay stable.
        return startOfMonth(.distantPast)
    }




       // MARK: - Progressive Loading Logic

    // wherever you add older months (e.g. appendOlderMonths or inside maybeLoadOlderIfNeeded)
    private func appendOlderMonths(batch: Int = 6) {
        guard let oldest = visibleMonths.last else { return }
        let frozenTop = topID
        let more = olderMonthsBatch(from: oldest, count: batch)    // ← now defined

        lockScrollPosition = true
        withTransaction(Transaction(animation: .none)) {
            visibleMonths.append(contentsOf: more)                 // newest … oldest
        }
        topID = frozenTop                                          // keep viewport fixed
        DispatchQueue.main.async {
            lockScrollPosition = false
        }
    }

    /// Returns up to `count` additional month starts that are **older** than `oldest`,
    /// ordered newest→oldest to match `visibleMonths` (which is newest…oldest).
    private func olderMonthsBatch(from oldest: Date, count: Int) -> [Date] {
        let cal = Calendar.current
        let floorEarliest = startOfMonth(earliestAvailableMonth)   // don’t go past this
        var results: [Date] = []
        var cursor = startOfMonth(oldest)
        var step = 1

        // avoid duplicates if we ever call this twice quickly
        let existing = Set(visibleMonths.map { startOfMonth($0) })

        while results.count < count {
            guard let candidate = cal.date(byAdding: .month, value: -step, to: cursor) else { break }
            if candidate < floorEarliest { break }                 // stop at earliest month we have
            if !existing.contains(candidate) {
                results.append(candidate)                          // append in newest→oldest order
            }
            step += 1
        }
        return results
    }




    private func startNextEdit() {
        guard pendingLocalID == nil else { return }   // already presenting
        guard let next = editQueue.first else { return }
        pendingLocalID = ClipLocalID(localID: next)
    }

    // ─── Helper models
    // in CalendarView
    struct Day: Identifiable {
        let id: Date
        let number: Int
        let thumbData: Data?      // ← was thumbnail: UIImage?
        let clipCount: Int
        let rotationDegrees: Double
        let emptyBadge: DayEmptyBadge?
    }

    private struct DayMetrics {
        let thumbData: Data?
        let clipCount: Int
        let rotationDegrees: Double

        static let empty = DayMetrics(
            thumbData: nil,
            clipCount: 0,
            rotationDegrees: 0
        )
    }


    struct SelectedDate: Identifiable, Hashable { let id: Date }
    // Number of clips in this project (recomputed whenever the store changes)

    @MainActor
    private var clipCount: Int {
        store.clips(from: .distantPast, to: Date(), in: project).count
    }

    private func withoutAnimation(_ updates: () -> Void) {
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t, updates)
    }

    @MainActor
    private func buildDay(for date: Date) -> Day? {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        guard date <= today else { return nil }

        let number = calendar.component(.day, from: date)

        // normalize once, then use the O(1) helpers
        let key = Calendar.current.startOfDay(for: date)
        let metrics = dayMetrics(for: key)

        let badge: DayEmptyBadge? = (metrics.thumbData == nil) ? monthPresence.badge(for: date) : nil

        return Day(
            id: date,
            number: number,
            thumbData: metrics.thumbData,
            clipCount: metrics.clipCount,
            rotationDegrees: metrics.rotationDegrees,
            emptyBadge: badge
        )
    }

    @MainActor
    private func dayMetrics(for key: Date) -> DayMetrics {
        if store.isLoaded {
            return DayMetrics(
                thumbData: store.firstThumbData(forDayKey: key, project: project),
                clipCount: store.count(forDayKey: key, project: project),
                rotationDegrees: store.firstClipRotation(forDayKey: key, project: project)
            )
        }

        if let entry = launchSnapshots.entry(forDayKey: key, projectID: project.id) {
            return DayMetrics(
                thumbData: entry.thumbData,
                clipCount: entry.clipCount,
                rotationDegrees: entry.rotationDegrees
            )
        }

        return .empty
    }

    private let heroDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = .current
        f.calendar = .current
        f.dateFormat = "MMM d, yyyy"   // e.g., Thursday, Aug 28, 2025
        return f
    }()

    /// Returns (quoteText, authorText) using ONLY the first 50 quotes.
    private func heroQuoteParts(for date: Date) -> (quote: String, author: String) {
        let authorCount = min(50, QuoteBank.quotes.count)
        guard authorCount > 0 else { return ("", "") }

        let cal = Calendar.current
        let dayOrdinal = cal.ordinality(of: .day, in: .era, for: date) ?? 0
        let idx = dayOrdinal % authorCount

        let full = QuoteBank.quotes[idx]

        // Split on the FIRST " — "
        let pieces = full.components(separatedBy: " — ")
        if pieces.count >= 2 {
            return (pieces[0].trimmingCharacters(in: .whitespacesAndNewlines),
                    pieces[1].trimmingCharacters(in: .whitespacesAndNewlines)) // ← no dash added
        } else {
            return (full, "")
        }
    }

    @ViewBuilder
    private func todayHeroRow(using day: Day) -> some View {
        let isToday  = Calendar.current.isDateInToday(day.id)
        let tileBG: Color = (day.thumbData != nil) ? .clear : T.core.surface


        HStack(alignment: .top, spacing: 14) {
            // LEFT: big square – reuse DayCell then add today highlight and center "+"
            ZStack {
                // BACKGROUND thumbnail (async decode)
                if let data = day.thumbData {
                    let ver = data.count
                    AsyncThumbImage(
                        data: data,
                        key: "day-\(project.id.uuidString)-\(day.id.timeIntervalSince1970)-v\(ver)"
                    )
                    .rotationEffect(.degrees(day.rotationDegrees))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))   // match hero shape
                }

                let ver = day.thumbData?.count ?? 0
                // FOREGROUND: your existing DayCell chrome (no eager decode)
                DayCell(
                    dayNumber: day.number,
                    thumbnail: nil,
                    asyncThumbData: day.thumbData,
                    thumbKey: "day-\(project.id.uuidString)-\(day.id.timeIntervalSince1970)-v\(ver)",
                    isToday: isToday,
                    clipCount: day.clipCount,
                    theme: DayCellTheme(
                        surface:    T.core.surface,
                        tileBG:     tileBG,
                        border:     T.border,
                        dateBadgeBG:T.core.primary,
                        dateBadgeFG:.white,
                        stackBG:    T.core.accent,
                        stackFG:    .white,
                        todayRing:  T.core.primary
                    ),
                    emptyBadge: day.emptyBadge,
                    weekdayAbbrev: day.id.formatted(.dateTime.weekday(.abbreviated)),
                    rotationDegrees: day.rotationDegrees
                )
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                if day.thumbData == nil {
                    Ph.plusCircle.fill
                        .color(T.core.accent)
                        .frame(width: 36, height: 36)
                        .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
                }


                // Highlight ring + glow
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(T.core.primary, lineWidth: 4)
                    .shadow(color: T.core.primary.opacity(0.45), radius: 8, y: 3)
            }
            .frame(
                width: layoutScale.calendarHeroTileSize,
                height: layoutScale.calendarHeroTileSize
            )
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .onTapGesture { selectedDate = SelectedDate(id: day.id) }
            .contextMenu {
                // Optional quick action, only when this day has clips
                if day.clipCount > 0 {
                    Button("Delete all clips for this day", role: .destructive) {
                        confirmDeleteDay = day.id
                    }
                }
            }
            // 5) CONFIRMATION – add a simple alert somewhere in body modifiers
            .alert("Delete all clips for this day?",
                   isPresented: isConfirmingDelete,
                   presenting: confirmDeleteDay) { day in
                Button("Delete", role: .destructive) {
                    for c in store.clips(for: day, in: project) { store.deleteClip(c) }
                    confirmDeleteDay = nil
                }
                Button("Cancel", role: .cancel) { confirmDeleteDay = nil }
            } message: { _ in
                Text("This removes all clips saved on that date.")
            }

            // RIGHT: author quote, separated into quote + author lines
            let parts = heroQuoteParts(for: day.id)

            VStack(alignment: .leading, spacing: 6) {
                // QUOTE line
                Text(parts.quote)
                    .font(.system(size: 15, weight: .regular, design: .rounded))
                    .foregroundStyle(T.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !parts.author.isEmpty {
                    Text(parts.author)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(T.textSecondary.opacity(0.75))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)   // centers within the quote block
                        .padding(.top, 2)
                }
            }
            .padding(.leading, 12)
            .frame(maxWidth: 180, alignment: .leading)   // ← keeps quote block narrow
            .frame(maxHeight: .infinity, alignment: .center)

        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private var heroSection: some View {
        if let heroDay = buildDay(for: Calendar.current.startOfDay(for: Date())) {
            VStack(spacing: 8) {
                Text(heroDateFormatter.string(from: heroDay.id))
                    .font(.system(
                        size: layoutScale.calendarHeroTitleSize,
                        weight: .heavy,
                        design: .rounded
                    ))
                    .foregroundStyle(T.core.text)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)


                todayHeroRow(using: heroDay)
            }
            .padding(.top, 0)

            Divider()
                .padding(.top, 20)

            Spacer().frame(height: 8)
        }
    }

    @ViewBuilder
    private var monthList: some View {
        LazyVStack(spacing: 12) {
            ForEach(visibleMonths, id: \.self) { month in
                Section(
                    header: monthHeader(for: month)

                ) {
                    let cal = Calendar.current
                    let isFirstDayToday  = cal.component(.day, from: Date()) == 1
                    let isCurrentMonth   = cal.isDate(month, equalTo: Date(), toGranularity: .month)
                    let showFirstDayHint = isFirstDayToday && isCurrentMonth
                    let monthName        = month.formatted(.dateTime.month(.wide))

                    if showFirstDayHint {
                        Text("Add your first memory for \(monthName) above.")
                            .font(.system(.footnote, design: .rounded))
                            .foregroundStyle(T.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 8)
                    } else {
                        dayGrid(for: month, excluding: isCurrentMonth ? cal.startOfDay(for: Date()) : nil)
                    }
                }
                .id(month)
                .onAppear { maybeLoadOlderIfNeeded(appearing: month) }
                .onAppear {
                    // Preload Photos presence for this month (one fetch, off-main)
                    monthPresence.preload(monthStart: startOfMonth(month))
                }
                .onAppear {
                    UserDefaults.standard.set(project.id.uuidString, forKey: "lastOpenedProjectID")
                }
            }
        }
        .animation(nil, value: visibleMonths)
        .scrollTargetLayout()
    }

    private var mainScroll: some View {
        ScrollView {
            Color.clear.frame(height: 14)    // top spacer under nav
            heroSection
            monthList
        }
        // iOS 17+: this keeps the viewport steady when we append older months
        .scrollPosition(id: lockScrollPosition ? $topID : .constant(nil as Date?))
        .scrollIndicators(.hidden)
        .onAppear {
            guard !didInitMonths else { return }

            earliestAvailableMonth = computeEarliestAvailableMonth()
            withoutAnimation {
                visibleMonths = lastMonths(3, endingAt: currentMonthStart)
            }

            didInitMonths = true

            Task.detached(priority: .background) {   // was .utility
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s, after nav animation

                let monthAssets = assetsForCurrentMonth()
                ImagePreheater.shared.preheat(monthAssets, pointSize: 160)
            }
        }
        .simultaneousGesture(
            TapGesture().onEnded {
                if showPlusMenu {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                        showPlusMenu = false
                    }
                }
            }
        )
    }






    // MARK: – Body
    var body: some View {
        contentWithNotifications
            .task {
                store.loadOnceIfNeeded()
            }
    }

    private var baseContent: some View {
        ZStack(alignment: .bottom) {
            T.core.surface.ignoresSafeArea()
            mainScroll
        }
    }

    private var contentWithToolbars: some View {
        baseContent
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 0) {
                        toolbarActionButton(
                            icon: .smartFill,
                            accessibilityLabel: "Smart Fill",
                            tint: T.core.primary,
                            action: presentSmartFillSheet
                        )
                        toolbarActionButton(
                            icon: .library,
                            accessibilityLabel: "Import from Library",
                            tint: T.core.primary,
                            action: presentLibraryPicker
                        )
                    }
                    .padding(.trailing, toolbarTrailingInset)
                }
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(project.name)
                        .font(.system(
                            size: layoutScale.calendarNavTitleSize,
                            weight: .semibold,
                            design: .rounded
                        ))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .foregroundStyle(T.core.text)
                        .accessibilityAddTraits(.isHeader)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: { dismiss() }) {
                        HStack(spacing: 4) {
                            Ph.caretLeft.regular
                                .color(T.core.text)
                                .frame(
                                    width: layoutScale.calendarBackIconSize,
                                    height: layoutScale.calendarBackIconSize
                                )
                        }
                    }
                    .accessibilityLabel("Back to Projects")
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(true)
    }

    private var contentWithOverlays: some View {
        contentWithToolbars
            .overlay(alignment: .top) {
                if shouldShowFirstProjectRecoveryCard {
                    firstProjectRecoveryCard
                        .padding(.horizontal, 16)
                        .padding(.top, 10)
                        .zIndex(30)
                }
            }
            .overlay(alignment: .bottom) {
                HStack {
                    Spacer(minLength: 0)
                    quickBar
                    Spacer(minLength: 0)
                }
                .zIndex(5)
            }
            .overlay(alignment: .bottom) {
                if askToKeep {
                    SmartFillToast(
                        freshCount: fillVM.freshDates.count,
                        confirm: {
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            fillVM.resetHighlight(); askToKeep = false
                        },
                        discard: {
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            Task {
                                for d in fillVM.freshDates { store.deleteClip(for: d, in: project) }
                                fillVM.resetHighlight(); askToKeep = false
                            }
                        }
                    )

                    .padding(.vertical, 10)
                    .frame(maxWidth: 560)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, toastBottomLift)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .animation(.easeOut(duration: 0.25), value: askToKeep)
                    .zIndex(20)
                }
            }
            .overlay {
                if showSmartFillSheet {
                    ZStack {
                        Color.black.opacity(0.35)
                            .ignoresSafeArea()
                            .onTapGesture {
                                withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                                    showSmartFillSheet = false
                                }
                            }
                        SmartFillSheetHost(T: T, project: project) {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                                showSmartFillSheet = false
                            }
                        }
                        .padding(.horizontal, 24)
                        .transition(.scale.combined(with: .opacity))
                    }
                    .zIndex(40)
                }
            }
    }

    private var contentWithSheets: some View {
        contentWithOverlays
            .sheet(isPresented: $showLibraryPicker) {
                NavigationStack {
                    LibraryPickerView(project: project, T: T, forEditing: true)
                }
            }
            .fullScreenCover(isPresented: $showCapture) {
                CaptureView(project: project, targetDate: Date())
                    .environmentObject(store)
            }
            .fullScreenCover(item: $selectedDate) { sel in
                NavigationStack {
                    DayPreviewPager(project: project, date: sel.id)
                        .environmentObject(store)
                }
            }
            .sheet(item: $pendingLocalID) { item in
                editorSheetForLocalID(item)
            }
            .sheet(item: $pendingCapturedURL) { item in
                editorSheetForCapturedURL(item)
            }
            .fullScreenCover(isPresented: $showMontage) {
                montageFullScreen
            }
    }

    private var contentWithNotifications: some View {
        contentWithSheets
            .onAppear {
                launchSnapshots.refreshIfPossible(from: store, project: project)
            }
            .onReceive(store.objectWillChange) { _ in
                launchSnapshots.scheduleRefresh(from: store, project: project)
            }
            .onReceive(NotificationCenter.default.publisher(for: .libraryPickerPicked)) { note in
                if let id = note.userInfo?["localIdentifier"] as? String {
                    editQueue = [id]
                    launchEditorAfterPickerDismiss = true
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .libraryPickerPickedMany)) { note in
                if let ids = note.userInfo?["localIdentifiers"] as? [String] {
                    var seen = Set<String>()
                    editQueue = ids.filter { seen.insert($0).inserted }
                    launchEditorAfterPickerDismiss = true
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .captureDidProduceURL)) { note in
                // If DayPreviewView is open (selectedDate != nil), let it handle the notification
                guard selectedDate == nil else { return }
                guard let url = note.userInfo?["url"] as? URL else { return }
                let item = URLItem(url: url)
                capturedURLBuffer = item
                if showCapture {
                    launchEditorAfterCaptureDismiss = true
                } else if pendingCapturedURL == nil {
                    DispatchQueue.main.async { pendingCapturedURL = item }
                }
            }
            .onChange(of: showLibraryPicker) { isShowing in
                if !isShowing, launchEditorAfterPickerDismiss, !editQueue.isEmpty, pendingLocalID == nil {
                    launchEditorAfterPickerDismiss = false
                    DispatchQueue.main.async { startNextEdit() }
                }
            }
            .onChange(of: showCapture) { isShowing in
                if !isShowing, launchEditorAfterCaptureDismiss,
                   let buffered = capturedURLBuffer, pendingCapturedURL == nil {
                    launchEditorAfterCaptureDismiss = false
                    capturedURLBuffer = nil
                    DispatchQueue.main.async { pendingCapturedURL = buffered }
                }
            }
            .onChange(of: fillVM.filling) { running in
                handleFillDone(running)
            }
    }

    private var shouldShowFirstProjectRecoveryCard: Bool {
        !onboard.hasCompletedOnboarding
            && project.name == "My First Project"
            && (store.countByProject[project.id] ?? 0) == 0
    }

    private var photosRecoveryRequiresSettings: Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        return status == .denied || status == .restricted
    }

    private var firstProjectRecoveryCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add your first moments")
                .font(.system(.headline, design: .rounded).weight(.semibold))
                .foregroundStyle(T.core.text)

            Text(
                photosRecoveryRequiresSettings
                    ? "Turn on photo access in Settings to pull in your recent clips and start building your first story."
                    : "Bring in a few clips from your library or capture a new moment so My First Project starts feeling real."
            )
            .font(.system(.callout, design: .rounded))
            .foregroundStyle(T.textSecondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button(action: {
                    if photosRecoveryRequiresSettings {
                        NotificationManager.openSystemSettings()
                    } else {
                        presentLibraryPicker()
                    }
                }) {
                    Text(photosRecoveryRequiresSettings ? "Enable Photos in Settings" : "Add from Library")
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .background(T.core.accent)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                Button(action: { showCapture = true }) {
                    Text("Capture now")
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .background(T.surfaceAlt)
                .foregroundStyle(T.core.text)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(T.core.surface)
                .shadow(color: .black.opacity(scheme == .dark ? 0.24 : 0.08), radius: 12, y: 6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(T.border, lineWidth: 1)
        )
    }

    // Helper views to break up complexity
    @ViewBuilder
    private func editorSheetForLocalID(_ item: ClipLocalID) -> some View {
        let targetDate = Calendar.current.startOfDay(for: Date())
        ClipEditorSheet(
            project: project,
            date: targetDate,
            initialURL: nil,
            editingClip: nil,
            sourceLocalID: item.localID,
            onSave: { url, thumb, duration, start, srcID, rotation, previewFillRaw, zoom, pan in
                let day = resolveAssetDay(srcID)
                store.addClip(
                    for: targetDate,
                    project: project,
                    fromURL: url,
                    thumb: thumb,
                    duration: duration,
                    isSmartFill: false,
                    start: start,
                    sourceLocalID: srcID,
                    rotationDegrees: rotation,
                    previewFillRaw: previewFillRaw,
                    zoomScale: zoom,
                    panOffset: pan
                )
                if !editQueue.isEmpty { editQueue.removeFirst() }
                pendingLocalID = nil
                if !editQueue.isEmpty {
                    DispatchQueue.main.async { startNextEdit() }
                }
            },
            onCancel: {
                if !editQueue.isEmpty { editQueue.removeFirst() }
                pendingLocalID = nil
                if !editQueue.isEmpty {
                    DispatchQueue.main.async { startNextEdit() }
                }
            }
        )
        .id(item.id)
    }

    @ViewBuilder
    private func editorSheetForCapturedURL(_ item: URLItem) -> some View {
        let targetDate = Calendar.current.startOfDay(for: Date())
        ClipEditorSheet(
            project: project,
            date: targetDate,
            initialURL: item.url,
            editingClip: nil,
            sourceLocalID: nil,
            onSave: { url, thumb, duration, start, srcID, rotation, previewFillRaw, zoom, pan in
                store.addClip(
                    for: targetDate,
                    project: project,
                    fromURL: url,
                    thumb: thumb,
                    duration: duration,
                    isSmartFill: false,
                    start: start,
                    sourceLocalID: srcID,
                    rotationDegrees: rotation,
                    previewFillRaw: previewFillRaw,
                    zoomScale: zoom,
                    panOffset: pan
                )
                pendingCapturedURL = nil
            },
            onCancel: {
                pendingCapturedURL = nil
            }
        )
    }

    @ViewBuilder
    private var montageFullScreen: some View {
        // IMPORTANT: Always use the same MontageView initializer with a stable identity.
        // Using conditional view creation (if/else with different initializers) causes
        // SwiftUI to recreate the entire MontageView when sheets are presented,
        // losing all state and triggering unnecessary rebuilds.
        MontageView(project: project, T: T)
            .id(project.id)  // Stable identity prevents recreation
    }


    private func maybeLoadOlderIfNeeded(appearing month: Date) {
        guard !isLoadingMore,
              month > earliestAvailableMonth
        else { return }

        // If we have at least 2 months, trigger when the penultimate becomes visible
        if visibleMonths.count >= 2,
           month == visibleMonths.dropLast().last {
            isLoadingMore = true
            appendOlderMonths(batch: 6)
            isLoadingMore = false
        }
    }


    private func performDelete() {
        for day in selection {
            for clip in store.clips(for: day, in: project) {
                store.deleteClip(clip)
            }
        }
        selection.removeAll()
        withAnimation(.easeInOut) {
            isEditing = false
        }
    }


    private func monthHeader(for month: Date) -> some View {
        let monthText = month.formatted(.dateTime.month(.wide)).uppercased()
        let yearText = month.formatted(.dateTime.year())

        let title: Text =
            Text(monthText)
                .font(.system(
                    size: layoutScale.calendarMonthTitleSize,
                    weight: .heavy,
                    design: .rounded
                ))
                .tracking(0.6)
                .foregroundStyle(T.core.primary.darken(0.35))
            + Text(" \(yearText)")
                .font(.system(
                    size: layoutScale.calendarMonthYearSize,
                    weight: .semibold,
                    design: .rounded
                ))
                .foregroundStyle(T.core.primary.darken(0.35).opacity(0.7))


        return HStack {
            title
            Spacer()
        }
        .padding(.top, 8)
        .padding(.horizontal, 12)
        .background(T.core.surface.ignoresSafeArea(edges: .horizontal))
    }

    private var gridColumns: [GridItem] {
        Array(
            repeating: .init(.flexible(), spacing: layoutScale.calendarGridSpacing),
            count: layoutScale.calendarGridColumns
        )
    }

    private func dayGrid(for month: Date, excluding exclude: Date? = nil) -> some View {
        LazyVGrid(
            columns: gridColumns,
            spacing: layoutScale.calendarGridSpacing
        ) {
            let allDays = days(for: month, excluding: exclude)
            let cols = gridColumns.count
            let rows = Int(ceil(Double(allDays.count) / Double(cols)))

            ForEach(Array(allDays.enumerated()), id: \.element.id) { idx, day in
                let isLastCol = (idx % cols) == cols - 1
                let isLastRow = (idx / cols) == rows - 1

                dayCell(for: day)
                    .overlay(
                        GridCellBorders(
                            color: T.border,
                            highlight: .white.opacity(0.12),
                            line: hairline,
                            drawRight: isLastCol,
                            drawBottom: isLastRow
                        )
                    )
                    .modifier(ScrollFadeScale())
                    .id(day.id)
                    .contentShape(Rectangle())
                    .contextMenu {
                        if day.clipCount > 0 {
                            Button("Delete all clips for this day", role: .destructive) {
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                confirmDeleteDay = day.id
                            }
                        }
                    }
                    .onTapGesture {
                        if isEditing {
                            if selection.contains(day.id) { selection.remove(day.id) }
                            else { selection.insert(day.id) }
                        } else {
                            currentMonth = day.id
                            selectedDate = SelectedDate(id: day.id)
                        }
                    }
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }


    @ViewBuilder
    private func dayCell(for day: Day) -> some View {
        let isToday    = Calendar.current.isDateInToday(day.id)
        let liveRotation = day.rotationDegrees
        let liveThumbData = day.thumbData
        let liveClipCount = day.clipCount
        let ver = liveThumbData?.count ?? -1                 // -1 means “no thumb”

        let tileBG: Color = (liveThumbData != nil) ? .clear : T.core.surface
        let cellCorner: CGFloat = 10

        ZStack {
            // --- THUMBNAIL LAYER (refreshes independently) ---
            Group {
                if let data = liveThumbData {
                    AsyncThumbImage(
                        data: data,
                        key: "day-\(project.id.uuidString)-\(day.id.timeIntervalSince1970)-v\(ver)"
                    )
                    .rotationEffect(.degrees(liveRotation))
                    .clipped()
                } else {
                    // If we just deleted the last clip, aggressively hide any stale bitmap for a frame
                    T.core.surface
                        .transition(.opacity)
                }
            }
            // Refresh ONLY this layer when ver changes
            .id("thumb-\(day.id.timeIntervalSince1970)-v\(ver)")
            // No layout/scroll animations on thumb changes
            .animation(nil, value: ver)

            // --- CHROME LAYER (unchanged; reads cached Day values is fine) ---
            DayCell(
                dayNumber: day.number,
                thumbnail: nil,
                asyncThumbData: liveThumbData, // keep feeding live for badge logic
                thumbKey: "day-\(project.id.uuidString)-\(day.id.timeIntervalSince1970)-v\(ver)",
                isToday: isToday,
                clipCount: liveClipCount,
                theme: DayCellTheme(
                    surface:    T.core.surface,
                    tileBG:     tileBG,
                    border:     T.border,
                    dateBadgeBG: T.core.primary,   // ← show chip (BG)
                    dateBadgeFG: .white,           // ← show chip (text)
                    stackBG:    T.core.accent,
                    stackFG:    .white,
                    todayRing:  T.core.primary
                ),
                emptyBadge: day.emptyBadge,
                weekdayAbbrev: day.id.formatted(.dateTime.weekday(.abbreviated)),
                rotationDegrees: liveRotation
            )
            .overlay {
                if liveClipCount == 0 && liveThumbData == nil {
                    RoundedRectangle(cornerRadius: cellCorner)
                        .inset(by: 4)
                        .stroke(T.border.opacity(0.6),
                                style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
            }
        }
    }




    // Put this somewhere in CalendarView.swift
    private var montageSymbol: String {
        if #available(iOS 16.0, *) { return "play.fill" }
        else { return "play.fill" } // fallback
    }

    @ViewBuilder
    private var plusMenu: some View {
        HStack(spacing: 20) {
            // Capture now
            Button {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                    showPlusMenu = false
                }
                showCapture = true
            } label: {
                VStack(spacing: 8) {
                    Circle()
                        .fill(T.core.accent)
                        .frame(width: 46, height: 46)
                        .overlay(
                            Ph.camera.fill
                                .color(.white)
                                .frame(width: 22, height: 22)
                        )

                    Text("Capture")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(T.core.text)
                }
            }

            // Import from Library
            Button {
                presentLibraryPicker()
            } label: {
                VStack(spacing: 8) {
                    Circle()
                        .fill(T.core.primary)
                        .frame(width: 46, height: 46)
                        .overlay(
                            Ph.images.regular
                                .color(.white)
                                .frame(width: 22, height: 22)
                        )

                    Text("Library")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(T.core.text)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(T.core.surface)
                .shadow(color: .black.opacity(0.25), radius: 10, y: 6)
        )
        .fixedSize()
    }



    @ViewBuilder
    private var quickBar: some View {
        HStack(spacing: 18) {
            // LEFT — Plus with overlay menu
            QuickIconButton(
                symbol: "plus",
                bg: T.core.accent, fg: .white,
                size: 68, emphasis: true
            ) {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                    showPlusMenu.toggle()
                }
            }
            .overlay(alignment: .top) {
                if showPlusMenu {
                    plusMenu
                        .offset(y: -92) // lift the menu above the plus button
                        .transition(.scale.combined(with: .opacity))
                }
            }
            // RIGHT — Play Montage (secondary)
            QuickIconButton(
                symbol: montageSymbol,
                bg: T.core.primary, fg: .white,
                size: 68, emphasis: true
            ) {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                if showPlusMenu {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                        showPlusMenu = false
                    }
                }
                makeAllClipsMontage()
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, quickBarBottomPadding)
    }

    private enum ToolbarActionIcon {
        case smartFill
        case library
    }

    private var toolbarTrailingInset: CGFloat {
        UIScreen.main.bounds.width <= 390 ? 4 : 8
    }

    private var toolbarActionButtonWidth: CGFloat {
        UIScreen.main.bounds.width <= 390 ? 34 : 40
    }

    private func toolbarActionButton(
        icon: ToolbarActionIcon,
        accessibilityLabel: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            toolbarActionIcon(icon: icon, tint: tint)
                .frame(width: toolbarActionButtonWidth, height: 40)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private func toolbarActionIcon(icon: ToolbarActionIcon, tint: Color) -> some View {
        switch icon {
        case .smartFill:
            Ph.lightning.fill
                .frame(width: 22, height: 22)
                .color(tint)
        case .library:
            Ph.images.fill
                .frame(width: 22, height: 22)
                .color(tint)
        }
    }


    // MARK: – Logic helpers
    private func closePlusMenuIfNeeded() {
        guard showPlusMenu else { return }
        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
            showPlusMenu = false
        }
    }

    private func presentSmartFillSheet() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        closePlusMenuIfNeeded()
        showSmartFillSheet = true
    }

    private func presentLibraryPicker() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        closePlusMenuIfNeeded()
        showLibraryPicker = true
    }

    private func handleFillDone(_ running: Bool) {
        if !running && !fillVM.freshDates.isEmpty { askToKeep = true }
    }

    private func days(for month: Date, excluding exclude: Date? = nil) -> [Day] {
        let calendar = Calendar.current
        let comps    = calendar.dateComponents([.year, .month], from: month)
        let range    = calendar.range(of: .day, in: .month, for: month)!
        let today    = calendar.startOfDay(for: .now)

        var items: [Day] = range.compactMap { d in
            var dc = comps; dc.day = d
            guard let date = calendar.date(from: dc) else { return nil }
            if let exclude, calendar.isDate(date, inSameDayAs: exclude) { return nil }
            return buildDay(for: date)
        }

        // If you’re using reversed descending days, keep this:
        items.reverse()
        return items
    }




    private func makeAllClipsMontage() {
        guard (store.countByProject[project.id] ?? 0) > 0 else {
            print("makeAllClipsMontage: no clips in this project")
            return
        }

        showMontage = true
    }


    private func assetsForCurrentMonth(limit: Int = 120) -> [PHAsset] {
        let cal = Calendar.current
        let now = Date()
        let start = cal.date(from: cal.dateComponents([.year, .month], from: now))!
        let end   = cal.date(byAdding: DateComponents(month: 1, day: -1), to: start) ?? now

        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        opts.predicate = NSPredicate(format: "mediaType == %d AND creationDate >= %@ AND creationDate <= %@",
                                     PHAssetMediaType.video.rawValue, start as NSDate, end as NSDate)
        opts.fetchLimit = limit

        let result = PHAsset.fetchAssets(with: .video, options: opts)
        var out: [PHAsset] = []
        out.reserveCapacity(min(limit, result.count))
        result.enumerateObjects { a, _, _ in out.append(a) }
        return out
    }

}

// MARK: – Calendar helper
extension Calendar {
    /// 7-day interval ending *now* (today + previous 6 days, inclusive)
    func pastWeekInterval(endingAt now: Date = Date()) -> DateInterval {
        let todayStart    = startOfDay(for: now)
        let weekAgoStart  = date(byAdding: .day, value: -6, to: todayStart)!
        return DateInterval(start: weekAgoStart, end: now)
    }
}

// Moved to CalendarViewModel.swift
// @MainActor
// final class CalendarSmartFillVM: ObservableObject { ... }

// Moved to CalendarHelpers.swift
// SmartFillSheetHost, SmartFillToast, QuickIconButton, ScaledTap, GridCellBorders, ScrollFadeScale, resolveAssetDay

// MARK: - DayPreviewPager Stable Container
// This wrapper prevents the infinite re-creation loop that occurs when
// navigationDestination(item:) re-evaluates its closure on every parent body evaluation.
// By using Equatable conformance, SwiftUI skips re-rendering when props haven't changed.
private struct DayPreviewPagerContainer: View, Equatable {
    let project: Project
    let date: Date

    static func == (lhs: DayPreviewPagerContainer, rhs: DayPreviewPagerContainer) -> Bool {
        lhs.project.id == rhs.project.id && lhs.date == rhs.date
    }

    var body: some View {
        DayPreviewPager(project: project, date: date)
    }
}
