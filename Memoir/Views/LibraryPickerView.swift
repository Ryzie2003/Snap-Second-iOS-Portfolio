// LibraryPickerView.swift
import SwiftUI
import Photos
import AVFoundation
import PhosphorSwift

extension Notification.Name {
    static let libraryPickerPicked = Notification.Name("LibraryPickerPicked")
    static let libraryPickerPickedMany = Notification.Name("LibraryPickerPickedMany")
}

private let dayHeaderFormatter: DateFormatter = {
    let df = DateFormatter()
    df.dateStyle = .medium
    return df
}()

// MARK: - Photos-style grouping
private enum Grouping: String, CaseIterable, Identifiable {
    case all = "All", month = "Months", year = "Years"
    var id: String { rawValue }
}

private enum MediaFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case photos = "Photos"
    case videos = "Videos"

    var id: String { rawValue }
    var title: String { rawValue }

    var systemImage: String {
        switch self {
        case .all: return "line.3.horizontal.decrease"
        case .photos: return "photo"
        case .videos: return "video"
        }
    }

    func includes(_ asset: PHAsset) -> Bool {
        switch self {
        case .all:
            return true
        case .photos:
            return asset.mediaType == .image
        case .videos:
            return asset.mediaType == .video
        }
    }
}

struct LibraryPickerView: View {
    let project: Project
    let T: Theme                   // ← inject CalendarView theme
    var forEditing: Bool = false

    @StateObject private var viewModel: LibraryPickerViewModel
    let seedDate: Date?
    let singleDayOnly: Bool

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var onboard: OnboardState

    @State private var predownloaded: [String: URL] = [:]

    @State private var showReadyPrompt = false
    @State private var grouping: Grouping = .all
    @State private var mediaFilter: MediaFilter = .all
    @State private var didStartImport = false
    @State private var didPostEditNotification = false

    // download from iCloud
    @State private var downloadingAssetID: String? = nil
    @State private var isPreparingSelection = false
    @State private var perAssetProgress: [String: Double] = [:]   // localID → 0…1

    // One-by-one edit queue (unchanged)
    private struct PendingEdit: Identifiable, Hashable {
        let id: String          // PHAsset.localIdentifier
        let date: Date          // normalized to startOfDay
    }
    @State private var pending: PendingEdit?
    @State private var editQueue: [PendingEdit] = []

    init(project: Project, T: Theme, forEditing: Bool = false, seedDate: Date? = nil, singleDayOnly: Bool = false) {
        self.project = project
        self.T = T
        self.forEditing = forEditing
        self.seedDate = seedDate
        self.singleDayOnly = singleDayOnly
        _viewModel = StateObject(wrappedValue: LibraryPickerViewModel(project: project))
    }


    // MARK: - Derived
    private var selectionCount: Int { viewModel.selectedAssets.count }
    private var bottomButtonTitle: String {
        if forEditing { return selectionCount <= 1 ? "Edit" : "Edit (\(selectionCount))" }
        return selectionCount == 0 ? "Add" : "Add \(selectionCount)"
    }
    private var bottomButtonDisabled: Bool {
        selectionCount == 0 || viewModel.isImporting || isPreparingSelection
    }

    private func quickAddDurationLabel(_ seconds: Double) -> String {
        if abs(seconds.rounded() - seconds) < 0.001 {
            return "\(Int(seconds))s"
        }
        return String(format: "%.1fs", seconds)
    }

    private var defaultQuickAddLabel: String {
        "Quick Add • Default (\(quickAddDurationLabel(ClipDefaults.duration)))"
    }

    @State private var expandedMonthKey: DateComponents? = nil
    @State private var expandedYearKey: Int? = nil

    @State private var activeRequestIDs: [String: PHImageRequestID] = [:]              // image/video manager
    @State private var activeResourceIDs: [String: PHAssetResourceDataRequestID] = [:] // resource manager
    @State private var downloadGeneration: [String: Int] = [:]                          // localID → gen



    // MARK: - Theme’d scaffolding
    var body: some View {
        contentView
            .navigationTitle("")
            .toolbarBackground(T.core.surface, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar { toolbarContent }
            .safeAreaInset(edge: .bottom) { bottomActionBar }
            .alert("Import Failed", isPresented: errorIsPresented) {
                Button("OK") { viewModel.importError = nil }
            } message: {
                Text(viewModel.importError ?? "")
            }
            .onChange(of: viewModel.isImporting, perform: handleImportingChange)
            .onChange(of: grouping, perform: handleGroupingChange)
            .onChange(of: viewModel.selectedAssets, perform: handleSelectedAssetsChange)
            .onReceive(viewModel.$sections) { _ in
                sanitizeMediaFilter()
            }
            .onChange(of: expandedMonthKey) { _ in
                sanitizeMediaFilter()
            }
            .onChange(of: expandedYearKey) { _ in
                sanitizeMediaFilter()
            }
            .fullScreenCover(item: $pending, content: editorCoverView)
            .onAppear(perform: handleOnAppear)
    }

    @ViewBuilder
    private var contentView: some View {
        ZStack {
            T.core.surface.ignoresSafeArea()

            VStack(spacing: 10) {
                titleBar
                if !singleDayOnly {
                    groupingControl
                }
                mainList
                    .padding(.bottom, 8)
            }

            if viewModel.isImporting {
                importingOverlay
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            Button("Cancel") {
                cancelAllDownloads()
                dismiss()
            }
            .tint(T.core.text)
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            if hasMediaInCurrentContext {
                mediaFilterMenu
            }
        }
    }

    @ViewBuilder
    private func editorCoverView(for item: PendingEdit) -> some View {
        ClipEditorSheet(
            project: project,
            date: item.date,
            initialURL: predownloaded[item.id],
            editingClip: nil,
            sourceLocalID: item.id,
            onSave: { url, thumb, duration, start, srcID, rotation, previewFillRaw, zoom, pan in
                handleEditorSave(
                    itemID: item.id,
                    date: item.date,
                    url: url,
                    thumb: thumb,
                    duration: duration,
                    start: start,
                    srcID: srcID,
                    rotation: rotation,
                    previewFillRaw: previewFillRaw,
                    zoom: zoom,
                    pan: pan
                )
            },
            onCancel: {
                handleEditorCancel(itemID: item.id)
            }
        )
        .id(item.id)
    }

    private func handleImportingChange(_ importing: Bool) {
        if !importing && didStartImport {
            showReadyPrompt = true
            didStartImport = false
        }
    }

    private func handleGroupingChange(_ newGrouping: Grouping) {
        expandedMonthKey = nil
        expandedYearKey = nil
    }

    private func handleSelectedAssetsChange(_ newSel: Set<PHAsset>) {
        if let id = downloadingAssetID,
           !newSel.contains(where: { $0.localIdentifier == id }) {
            cancelDownload(for: id)
        }
    }

    private func handleEditorSave(
        itemID: String,
        date: Date,
        url: URL,
        thumb: UIImage,
        duration: Double,
        start: Double,
        srcID: String?,
        rotation: Double,
        previewFillRaw: String,
        zoom: Double,
        pan: CGPoint
    ) {
        predownloaded[itemID] = nil
        ClipStore.shared.addClip(
            for: date,
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
        if let next = editQueue.first {
            pending = next
        } else {
            onboard.finish()
            pending = nil
            dismiss()
        }
    }

    private func handleEditorCancel(itemID: String) {
        predownloaded[itemID] = nil
        if !editQueue.isEmpty { editQueue.removeFirst() }
        if let next = editQueue.first {
            pending = next
        } else {
            onboard.finish()
            pending = nil
        }
    }

    private func handleOnAppear() {
        viewModel.seed(startAt: seedDate, singleDayOnly: singleDayOnly)

        // Defer preheating so we don't compete with the nav transition
        Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 200_000_000)

            // Read UI state on the main actor, then use the snapshot off-main.
            let headSections: [AssetSection] = await MainActor.run {
                Array(viewModel.sections.prefix(5))
            }
            let firstAssets: [PHAsset] = Array(headSections.flatMap { $0.assets }.prefix(100))
            guard !firstAssets.isEmpty else { return }

            // Use a real caching manager instance
            let manager = PHCachingImageManager()
            let target = CGSize(width: 300, height: 300)
            let opts = PHImageRequestOptions()
            opts.deliveryMode = .opportunistic
            opts.isNetworkAccessAllowed = false

            manager.startCachingImages(
                for: firstAssets,
                targetSize: target,
                contentMode: .aspectFill,
                options: opts
            )
        }
    }

    private var titleBar: some View {
        HStack {
            if expandedMonthKey != nil || expandedYearKey != nil {
                Button {
                    expandedMonthKey = nil
                    expandedYearKey = nil
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                }
                .tint(T.core.text)
            }

            Text(expandedMonthKey != nil ? "Month" :
                 expandedYearKey != nil ? "Year" : "Select Clips")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(T.core.text)

            Spacer()

              if selectionCount > 0 {
                  Button("Deselect All") {
                      UIImpactFeedbackGenerator(style: .light).impactOccurred()
                      viewModel.deselectAll()
                  }
                  .buttonStyle(.plain)
                  .font(.system(size: 14, weight: .semibold, design: .rounded))
                  .foregroundStyle(T.core.primary)
                  .disabled(viewModel.isImporting || isPreparingSelection)
              }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }


    private var groupingControl: some View {
        HStack(spacing: 8) {
            ForEach(Grouping.allCases) { g in
                Button {
                    if grouping == g {
                        // Tapped the same tab again → reset drill-down
                        expandedMonthKey = nil
                        expandedYearKey = nil
                    } else {
                        grouping = g
                        // Always reset on tab switch
                        expandedMonthKey = nil
                        expandedYearKey = nil
                    }
                } label: {
                    Text(g.rawValue)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .padding(.vertical, 6)
                        .padding(.horizontal, 12)
                        .background(
                            grouping == g
                            ? T.core.primary.opacity(0.15)
                            : Color.clear
                        )
                        .clipShape(Capsule())
                        .foregroundStyle(
                            grouping == g ? T.core.primary : T.textSecondary
                        )
                }
            }
        }
        .padding(.horizontal, 16)
    }

    private var mediaFilterMenu: some View {
        Menu {
            Button {
                mediaFilter = .all
            } label: {
                Label("All", systemImage: mediaFilter == .all ? "checkmark" : MediaFilter.all.systemImage)
            }

            Divider()

            Button {
                mediaFilter = .photos
            } label: {
                Label("Photos", systemImage: mediaFilter == .photos ? "checkmark" : MediaFilter.photos.systemImage)
            }
            .disabled(!hasPhotoItemsInCurrentContext)

            Button {
                mediaFilter = .videos
            } label: {
                Label("Videos", systemImage: mediaFilter == .videos ? "checkmark" : MediaFilter.videos.systemImage)
            }
            .disabled(!hasVideoItemsInCurrentContext)
        } label: {
            Ph.funnel.regular
                .frame(width: 20, height: 20)
                .color(mediaFilter == .all ? T.core.text : T.core.primary)
                .accessibilityHidden(true)
        }
        .disabled(viewModel.isImporting)
        .accessibilityLabel("Filter media")
        .accessibilityHint("Shows media filter options")
    }


    @ViewBuilder
    private var mainList: some View {
        ScrollView {
            if singleDayOnly, let sd = seedDate.map({ Calendar.current.startOfDay(for: $0) }) {
                // Only the chosen day
                daySectionList(filter: { Calendar.current.isDate($0, inSameDayAs: sd) })
            } else if let monthKey = expandedMonthKey,
                      let y = monthKey.year, let m = monthKey.month {
                // Drill-down: show days in the selected month
                daySectionList(filter: {
                    let c = Calendar.current.dateComponents([.year, .month], from: $0)
                    return c.year == y && c.month == m
                })
            } else if let y = expandedYearKey {
                // Drill-down: show days in the selected year
                daySectionList(filter: {
                    Calendar.current.component(.year, from: $0) == y
                })
            } else {
                // existing multi-day UI (All / Months / Years) unchanged
                switch grouping {
                case .all:
                    daySectionList(filter: { _ in true })
                case .month:
                    let buckets = groupedSections()
                    if buckets.isEmpty {
                        filterEmptyState
                    } else {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(buckets, id: \.key) { bucket in
                                monthHero(bucket: bucket).padding(.horizontal, 16)
                            }
                        }
                        .padding(.top, 4)
                    }
                case .year:
                    let buckets = groupedSections()
                    if buckets.isEmpty {
                        filterEmptyState
                    } else {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(buckets, id: \.key) { bucket in
                                yearHero(bucket: bucket).padding(.horizontal, 16)
                            }
                        }
                        .padding(.top, 4)
                    }
                }
            }
        }
        .id(idForScrollIdentity)
    }

    // Unique id for ScrollView identity across drill-downs
    private var idForScrollIdentity: String {
        if let m = expandedMonthKey, let y = m.year, let mo = m.month { return "m-\(y)-\(mo)" }
        if let y = expandedYearKey { return "y-\(y)" }
        return grouping.id
    }



    @ViewBuilder
    private func daySectionList(filter: @escaping (Date) -> Bool) -> some View {
        let sections = filteredSections(matching: filter)
        if sections.isEmpty {
            filterEmptyState
        } else {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(sections, id: \.date) { section in
                    Section {
                        grid(of: section.assets)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 12)
                    } header: {
                        sectionHeader(for: section)
                            .padding(.horizontal, 16)
                            .background(T.core.surface)
                            .id(section.date)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    private func monthHero(bucket: Bucket) -> some View {
        Button {
            if let d = bucket.assets.first?.creationDate {
                let comps = Calendar.current.dateComponents([.year, .month], from: d)
                expandedMonthKey = comps
                expandedYearKey  = nil
            }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                if let asset = bucket.assets.first {
                    aspectFillThumb(asset: asset, showDayBadge: false)   // ← no day number
                        .frame(height: 240)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .overlay(alignment: .topLeading) {
                            Text(bucket.header ?? "")
                                .font(.system(size: 28, weight: .heavy, design: .rounded))
                                .foregroundStyle(.white)
                                .shadow(radius: 6, y: 3)
                                .padding(14)
                        }
                }
                // 🔻 REMOVE the mini preview grid entirely
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func yearHero(bucket: Bucket) -> some View {
        Button {
            if let d = bucket.assets.first?.creationDate {
                let y = Calendar.current.component(.year, from: d)
                expandedYearKey  = y
                expandedMonthKey = nil
            }
        } label: {
            if let asset = bucket.assets.first {
                aspectFillThumb(asset: asset, showDayBadge: false)       // ← no day number
                    .frame(height: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay(alignment: .topLeading) {
                        Text(bucket.header ?? "")
                            .font(.system(size: 32, weight: .heavy, design: .rounded))
                            .foregroundStyle(.white)
                            .shadow(radius: 6, y: 3)
                            .padding(14)
                    }
            }
        }
        .buttonStyle(.plain)
    }


    private func aspectFillThumb(asset: PHAsset, showDayBadge: Bool) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                AssetThumbnailView(asset: asset)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()

                if showDayBadge, let d = asset.creationDate {
                    let day = Calendar.current.component(.day, from: d)
                    Text("\(day)")
                        .font(.system(size: 18, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .shadow(radius: 4, y: 2)
                        .padding(8)
                }
            }
        }
    }


    private func grid(of assets: [PHAsset]) -> some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)
        return LazyVGrid(columns: columns, spacing: 8) {
            ForEach(assets, id: \.localIdentifier) { asset in
                AssetTile(
                    asset: asset,
                    T: T,
                    selected: viewModel.selectedAssets.contains(asset),
                    showProgress: perAssetProgress[asset.localIdentifier] != nil,
                    progress: perAssetProgress[asset.localIdentifier] ?? 0,
                    onTap: {
                        guard !viewModel.isImporting && !isPreparingSelection else { return }
                        // If this asset is downloading, cancel it before toggling off.
                        if viewModel.selectedAssets.contains(asset) {
                            cancelDownload(for: asset.localIdentifier)
                            predownloaded[asset.localIdentifier] = nil
                        }
                        viewModel.toggleSelection(asset)
                    }
                )
            }
        }
    }

    private func sectionHeader(for section: AssetSection) -> some View {
        HStack(spacing: 10) {
            Text(dayHeaderFormatter.string(from: section.date))
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(T.core.text)
        }
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    private var filterEmptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: mediaFilter == .all ? "photo.on.rectangle.angled" : mediaFilter.systemImage)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(T.textSecondary)

            Text(filterEmptyTitle)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(T.core.text)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
        .padding(.horizontal, 24)
    }

    private var filterEmptyTitle: String {
        switch mediaFilter {
        case .all:
            return "No photos or videos here"
        case .photos:
            return "No photos here"
        case .videos:
            return "No videos here"
        }
    }


    // MARK: - Bottom actions
    @ViewBuilder
    private var bottomActionBar: some View {
        HStack(spacing: 12) {
            // count chip
            Text(selectionCount == 0 ? "0 selected" : "\(selectionCount) selected")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(T.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(T.border.opacity(0.25))
                )

            Spacer(minLength: 0)

            // Secondary: Quick Add (menu for length)
            Menu {
                quickAddButton(label: defaultQuickAddLabel, length: ClipDefaults.duration)
                Divider()
                quickAddButton(label: "Quick Add • 1s", length: 1.0)
                quickAddButton(label: "Quick Add • 1.5s", length: 1.5)
                quickAddButton(label: "Quick Add • 3.0s", length: 3.0)
                quickAddButton(label: "Quick Add • 5.0s", length: 5.0)
            } label: {
                Label("Quick Add", systemImage: "bolt.fill")
                    .labelStyle(.titleAndIcon)
            }
            .menuStyle(.automatic)
            .font(.system(size: 15, weight: .semibold, design: .rounded))
            .disabled(bottomButtonDisabled)

            // Primary: Edit / Add
            Button(bottomButtonTitle) { handleConfirm() }
                .buttonStyle(.borderedProminent)
                .tint(T.core.accent)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .disabled(bottomButtonDisabled)

        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .overlay(Divider().overlay(T.border.opacity(0.35)), alignment: .top)
    }

    // Before: private func quickAddButton(label: String, length: Double) { ... }  // returns Void ❌
    // After  ⤵
    @ViewBuilder
    private func quickAddButton(label: String, length: Double) -> some View {
        Button(label) {
            guard !viewModel.selectedAssets.isEmpty else { return }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            didStartImport = true
            viewModel.importSelectedAssets(
                mode: .quickAdd(length: length, trim: true)
            ) { _ in
                didStartImport = false
                dismiss()
            }
        }
        .disabled(bottomButtonDisabled)
    }


    private func handleConfirm() {
        guard !viewModel.selectedAssets.isEmpty else { return }

        beginEditSelected()
    }

    private func beginEditSelected() {
        guard !viewModel.selectedAssets.isEmpty else { return }
        guard !isPreparingSelection else { return }

        // 1) Build the edit queue from the current selection (unique order)
        var seen = Set<String>()
        let cal = Calendar.current
        let assetsToPrepare = viewModel.selectedAssets
            .sorted {
                ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast)
            }
            .filter { seen.insert($0.localIdentifier).inserted }

        editQueue = assetsToPrepare.map { asset in
            let base = asset.creationDate ?? Date()
            return PendingEdit(id: asset.localIdentifier,
                               date: cal.startOfDay(for: base))
        }

        // 2) Prefetch every selected asset (download from iCloud if needed)
        isPreparingSelection = true
        Task { @MainActor in
            do {
                for asset in assetsToPrepare {
                    // skip if we already prepared this one (e.g., user tapped twice)
                    if predownloaded[asset.localIdentifier] != nil { continue }

                    downloadingAssetID = asset.localIdentifier
                    perAssetProgress[asset.localIdentifier] = 0

                    let id = asset.localIdentifier
                    let gen = (downloadGeneration[id] ?? 0) + 1
                    downloadGeneration[id] = gen

                    let payload = try await withMediaPreparationTimeout {
                        try await lp_fetchForEditing(
                            asset: asset,
                            onProgress: { p in
                                // Ignore late callbacks from a previous (canceled) generation
                                if downloadGeneration[id] == gen {
                                    perAssetProgress[id] = p
                                }
                            },
                            onImageManagerRequestID: { rid in activeRequestIDs[id] = rid },
                            onResourceRequestID: { rrid in activeResourceIDs[id] = rrid }
                        )
                    }


                    switch payload {
                    case .photo(let url):
                        predownloaded[asset.localIdentifier] = url
                    case .video(let url, _):
                        predownloaded[asset.localIdentifier] = url
                    }
                    activeRequestIDs[id] = nil
                    activeResourceIDs[id] = nil
                }
            } catch {
                if let id = downloadingAssetID {
                    cancelDownload(for: id)
                }
                // If user canceled, don't show an error toast.
                if error is CancellationError {
                    clearDownloadTracking()
                    return
                }
                viewModel.importError = "Couldn't download from iCloud."
                clearDownloadTracking()
                return
            }


            // 3) All ready → clear HUD, open the editor at the first item
            clearDownloadTracking()
            if let first = editQueue.first {
                pending = first
            }
        }
    }

    private func clearDownloadTracking() {
        downloadingAssetID = nil
        isPreparingSelection = false
        activeRequestIDs.removeAll()
        activeResourceIDs.removeAll()

        var txn = Transaction()
        txn.disablesAnimations = true
        withTransaction(txn) {
            perAssetProgress.removeAll()
        }
    }

    private func cancelDownload(for localID: String) {
        // Invalidate any in-flight callbacks for this asset
        downloadGeneration[localID] = (downloadGeneration[localID] ?? 0) + 1

        // Stop both kinds of requests
        if let rid = activeRequestIDs.removeValue(forKey: localID) {
            PHImageManager.default().cancelImageRequest(rid)
        }
        if let rrid = activeResourceIDs.removeValue(forKey: localID) {
            PHAssetResourceManager.default().cancelDataRequest(rrid)
        }

        // Remove HUD immediately (no animation → no “jump”)
        var txn = Transaction()
        txn.disablesAnimations = true
        withTransaction(txn) {
            perAssetProgress[localID] = nil
            if downloadingAssetID == localID { downloadingAssetID = nil }
        }
    }

    private func cancelAllDownloads() {
        for (_, rid) in activeRequestIDs { PHImageManager.default().cancelImageRequest(rid) }
        for (_, rrid) in activeResourceIDs { PHAssetResourceManager.default().cancelDataRequest(rrid) }
        activeRequestIDs.removeAll()
        activeResourceIDs.removeAll()
        downloadingAssetID = nil
        isPreparingSelection = false
        downloadGeneration = [:]

        var txn = Transaction(); txn.disablesAnimations = true
        withTransaction(txn) { perAssetProgress.removeAll() }
    }






    // MARK: - Importing overlay
    @ViewBuilder
    private var importingOverlay: some View {
        Color.black.opacity(0.35).ignoresSafeArea()
        VStack(spacing: 14) {
            ProgressView("Adding…",
                         value: viewModel.importProgress,
                         total: 1.0)
            Text("\(Int(viewModel.importProgress * 100))%")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
        }
        .padding(22)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(radius: 8, y: 4)
    }

    // MARK: - Error alert binding
    private var errorIsPresented: Binding<Bool> {
        Binding(
            get: { viewModel.importError != nil },
            set: { if !$0 { viewModel.importError = nil } }
        )
    }

    // MARK: - Grouping logic (rebuckets the ViewModel’s sections)
    private struct Bucket: Identifiable {
        let id = UUID()
        let key: String              // grouping key (e.g., "2025-08" or "2025")
        let header: String?          // header string to show (nil for .all)
        let assets: [PHAsset]
    }

    private var hasMediaInCurrentContext: Bool {
        !currentContextSectionsUnfiltered.flatMap(\.assets).isEmpty
    }

    private var hasPhotoItemsInCurrentContext: Bool {
        let assets = currentContextSectionsUnfiltered.flatMap(\.assets)
        return assets.contains(where: { $0.mediaType == .image })
    }

    private var hasVideoItemsInCurrentContext: Bool {
        let assets = currentContextSectionsUnfiltered.flatMap(\.assets)
        return assets.contains(where: { $0.mediaType == .video })
    }

    private func sanitizeMediaFilter() {
        switch mediaFilter {
        case .all:
            return
        case .photos:
            if !hasPhotoItemsInCurrentContext {
                mediaFilter = .all
            }
        case .videos:
            if !hasVideoItemsInCurrentContext {
                mediaFilter = .all
            }
        }
    }

    private var currentContextSectionsUnfiltered: [AssetSection] {
        viewModel.sections.filter { dateMatchesCurrentContext($0.date) }
    }

    private func dateMatchesCurrentContext(_ date: Date) -> Bool {
        let cal = Calendar.current
        if singleDayOnly, let sd = seedDate.map({ cal.startOfDay(for: $0) }) {
            return cal.isDate(date, inSameDayAs: sd)
        }
        if let monthKey = expandedMonthKey,
           let y = monthKey.year,
           let m = monthKey.month {
            let comps = cal.dateComponents([.year, .month], from: date)
            return comps.year == y && comps.month == m
        }
        if let y = expandedYearKey {
            return cal.component(.year, from: date) == y
        }
        return true
    }

    private func filteredSections(matching dateFilter: (Date) -> Bool) -> [AssetSection] {
        viewModel.sections.compactMap { section in
            guard dateFilter(section.date) else { return nil }
            let assets = filteredAssets(section.assets)
            guard !assets.isEmpty else { return nil }
            return AssetSection(date: section.date, assets: assets)
        }
    }

    private func filteredAssets(_ assets: [PHAsset]) -> [PHAsset] {
        assets.filter { mediaFilter.includes($0) }
    }

    private func globallyFilteredAssets(_ assets: [PHAsset]) -> [PHAsset] {
        assets.filter { mediaFilter.includes($0) }
    }

    private func groupedSections() -> [Bucket] {
        let allPairs: [(Date, PHAsset)] = currentContextSectionsUnfiltered.flatMap { section in
            globallyFilteredAssets(section.assets).map { (section.date, $0) }
        }

        switch grouping {
        case .all:
            let assets = allPairs.map { $0.1 }
            return [Bucket(key: "all", header: nil, assets: assets)]
        case .month:
            let groups = Dictionary(grouping: allPairs) { (_, asset) in
                startOfMonth(asset.creationDate ?? Date())
            }
            let keys = groups.keys.sorted(by: >)
            return keys.map { monthStart in
                let assets = groups[monthStart]?.map { $0.1 } ?? []
                return Bucket(
                    key: keyMonth(monthStart),
                    header: headerMonth(monthStart),
                    assets: assets
                )
            }
        case .year:
            let groups = Dictionary(grouping: allPairs) { (_, asset) in
                startOfYear(asset.creationDate ?? Date())
            }
            let keys = groups.keys.sorted(by: >)
            return keys.map { yearStart in
                let assets = groups[yearStart]?.map { $0.1 } ?? []
                return Bucket(
                    key: keyYear(yearStart),
                    header: headerYear(yearStart),
                    assets: assets
                )
            }
        }
    }

    private func startOfMonth(_ date: Date) -> Date {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month], from: date)
        return cal.date(from: comps) ?? date
    }
    private func startOfYear(_ date: Date) -> Date {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year], from: date)
        return cal.date(from: comps) ?? date
    }

    private func headerMonth(_ date: Date) -> String {
        let m = date.formatted(.dateTime.month(.wide))
        let y = date.formatted(.dateTime.year())
        return "\(m) \(y)"
    }
    private func headerYear(_ date: Date) -> String {
        date.formatted(.dateTime.year())
    }
    private func keyMonth(_ date: Date) -> String {
        let y = date.formatted(.dateTime.year())
        let m = date.formatted(.dateTime.month(.twoDigits))
        return "\(y)-\(m)"
    }
    private func keyYear(_ date: Date) -> String {
        date.formatted(.dateTime.year())
    }

    // MARK: - Tile with iCloud badge probe
    private struct AssetTile: View {
        let asset: PHAsset
        let T: Theme
        let selected: Bool
        let showProgress: Bool
        let progress: Double
        let onTap: () -> Void

        @State private var isInCloud: Bool? = nil

        var body: some View {
             GeometryReader { cell in
               ZStack(alignment: .topLeading) {
                 // thumbnail
                 AssetThumbnailView(asset: asset)
                   .frame(width: cell.size.width, height: cell.size.width)
                   .clipped()
                 // day badge (top-left)
                 if let d = asset.creationDate {
                   Text("\(Calendar.current.component(.day, from: d))")
                     .font(.system(size: 18, weight: .heavy, design: .rounded))
                     .foregroundStyle(.white)
                     .shadow(radius: 4, y: 2)
                     .padding(8)
                 }
               }
               .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
               .overlay(alignment: .bottomTrailing) { typeBadgeLocal(for: asset) }
                    .overlay(selectionOverlay) // selection ring/checkmark
                    .overlay { if showProgress { perTileProgressHUD(progress) } }
                    .overlay(alignment: .topLeading) {
                        if (isInCloud == true) && !showProgress {
                            icloudBadge
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { onTap() }
            }
            .aspectRatio(1, contentMode: .fit)
            .onAppear { checkCloudStatus() }
            .onChange(of: asset.localIdentifier) { _ in checkCloudStatus() }
        }

        private var icloudBadge: some View {
            Image(systemName: "icloud")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .padding(6)
                .background(.black.opacity(0.65), in: Capsule())
                .padding(6)
                .allowsHitTesting(false)
        }

        private var selectionOverlay: some View {
            Group {
                if selected {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(T.core.primary, lineWidth: 2)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(T.primaryMuted)
                        )
                        .overlay(
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundStyle(.white)
                                .shadow(radius: 2, y: 1)
                                .padding(6),
                            alignment: .topTrailing
                        )
                }
            }
        }

        private func typeBadgeLocal(for asset: PHAsset) -> some View {
            let symbol: String? = {
                if asset.mediaType == .video {
                    return "video.fill"
                } else if asset.mediaSubtypes.contains(.photoLive) {
                    return "livephoto"
                } else if asset.mediaType == .image {
                    return "photo.fill"     // ← NEW: regular still photo
                } else {
                    return nil
                }
            }()

            return Group {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(5)
                        .background(.black.opacity(0.65), in: Capsule())
                        .padding(5)
                        .allowsHitTesting(false)
                }
            }
        }



        // Reuse your HUD look but pass progress in
        private func perTileProgressHUD(_ p: Double) -> some View {
            ZStack {
                Color.black.opacity(0.25)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(spacing: 8) {
                    ProgressView(value: max(0.05, p))
                        .progressViewStyle(.linear)
                        .frame(width: 90)
                    Text(progressLabel(for: p))
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                }
                .padding(10)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
                )
            }
        }

        private func progressLabel(for progress: Double) -> String {
            let clamped = min(1, max(0, progress))
            guard clamped > 0 else { return "Preparing..." }
            return "Preparing \(Int(max(0.05, clamped) * 100))%"
        }

        // Non-network iCloud detection for photo, Live Photo, and video
        private func checkCloudStatus() {
            if asset.mediaSubtypes.contains(.photoLive) {
                let o = PHLivePhotoRequestOptions()
                o.isNetworkAccessAllowed = false
                o.deliveryMode = .fastFormat
                PHImageManager.default().requestLivePhoto(
                    for: asset,
                    targetSize: .init(width: 64, height: 64),
                    contentMode: .aspectFit,
                    options: o
                ) { live, info in
                    let flag = (info?[PHImageResultIsInCloudKey] as? Bool) ?? (live == nil)
                    DispatchQueue.main.async { isInCloud = flag }
                }
                return
            }

            if asset.mediaType == .image {
                let o = PHImageRequestOptions()
                o.isNetworkAccessAllowed = false
                o.deliveryMode = .fastFormat
                PHImageManager.default().requestImageDataAndOrientation(for: asset, options: o) { data, _, _, info in
                    let flag = (info?[PHImageResultIsInCloudKey] as? Bool) ?? (data == nil)
                    DispatchQueue.main.async { isInCloud = flag }
                }
            } else {
                let o = PHVideoRequestOptions()
                o.isNetworkAccessAllowed = false
                o.deliveryMode = .fastFormat
                PHImageManager.default().requestAVAsset(forVideo: asset, options: o) { av, _, info in
                    let flag = (info?[PHImageResultIsInCloudKey] as? Bool) ?? (av == nil)
                    DispatchQueue.main.async { isInCloud = flag }
                }
            }
        }
    }

}



extension UIImage {
  /// Returns a version of this image with its `imageOrientation` normalized to `.up`.
  func fixedOrientation() -> UIImage {
    guard imageOrientation != .up else { return self }
    UIGraphicsBeginImageContextWithOptions(size, false, scale)
    draw(in: CGRect(origin: .zero, size: size))
    let normalized = UIGraphicsGetImageFromCurrentImageContext() ?? self
    UIGraphicsEndImageContext()
    return normalized
  }
}

private enum LPDownloadPayload {
    case photo(url: URL)
    case video(url: URL, avAsset: AVAsset)
}

@MainActor
private func lp_fetchForEditing(
    asset: PHAsset,
    onProgress: @escaping (Double) -> Void,
    onImageManagerRequestID: @escaping (PHImageRequestID) -> Void = { _ in },
    onResourceRequestID: @escaping (PHAssetResourceDataRequestID) -> Void = { _ in }
) async throws -> LPDownloadPayload {
    // Prefer downloading the ORIGINAL resource so iCloud transfers are explicit & cancellable.
    let resources = PHAssetResource.assetResources(for: asset)

    func downloadResource(_ res: PHAssetResource, ext: String) async throws -> URL {
        try await withCheckedThrowingContinuation { cont in
            let opts = PHAssetResourceRequestOptions()
            opts.isNetworkAccessAllowed = true
            opts.progressHandler = { p in DispatchQueue.main.async { onProgress(p) } }

            // Prepare a temp file and a writable handle
            let out = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(ext)
            FileManager.default.createFile(atPath: out.path, contents: nil, attributes: nil)

            guard let handle = try? FileHandle(forWritingTo: out) else {
                cont.resume(throwing: NSError(domain: "lp_fetch", code: -20,
                                              userInfo: [NSLocalizedDescriptionKey: "Unable to open file for writing"]))
                return
            }

            // Declare request ID first so closures can reference it
            var rid: PHAssetResourceDataRequestID?

            // Define completion
            let completion: (Error?) -> Void = { error in
                try? handle.close()

                if let error {
                    let ns = error as NSError
                    if ns.code == NSUserCancelledError {
                        cont.resume(throwing: CancellationError())
                    } else {
                        cont.resume(throwing: error)
                    }
                } else {
                    cont.resume(returning: out)
                }
            }

            // Start the download
            rid = PHAssetResourceManager.default().requestData(
                for: res,
                options: opts,
                dataReceivedHandler: { chunk in
                    do {
                        try handle.write(contentsOf: chunk)
                    } catch {
                        if let rid { PHAssetResourceManager.default().cancelDataRequest(rid) }
                        cont.resume(throwing: error)
                    }
                },
                completionHandler: completion
            )

            // Pass request ID back so it can be canceled later
            if let rid { onResourceRequestID(rid) }
        }
    }

    // 1) LIVE PHOTO → prefer the paired movie
       if asset.mediaSubtypes.contains(.photoLive) {
           if let paired = resources.first(where: { $0.type == .pairedVideo }) {
               // Download the paired video to a temp .mov
               let out = URL(fileURLWithPath: NSTemporaryDirectory())
                   .appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")

               try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                   let opts = PHAssetResourceRequestOptions()
                   opts.isNetworkAccessAllowed = true
                   opts.progressHandler = { p in DispatchQueue.main.async { onProgress(p) } }

                   do {
                       if !FileManager.default.fileExists(atPath: out.path) {
                           FileManager.default.createFile(atPath: out.path, contents: nil)
                       }
                       let handle = try FileHandle(forWritingTo: out)

                       var rid: PHAssetResourceDataRequestID?
                       rid = PHAssetResourceManager.default().requestData(
                           for: paired,
                           options: opts,
                           dataReceivedHandler: { chunk in
                               do {
                                   try handle.seekToEnd()
                                   try handle.write(contentsOf: chunk)
                               } catch {
                                   if let rid { PHAssetResourceManager.default().cancelDataRequest(rid) }
                                   cont.resume(throwing: error)
                               }
                           },
                           completionHandler: { error in
                               do { try handle.close() } catch { /* ignore */ }
                               if let error { cont.resume(throwing: error) }
                               else { cont.resume(returning: ()) }
                           }
                       )
                       if let rid { onResourceRequestID(rid) }
                   } catch {
                       cont.resume(throwing: error)
                   }
               }

               return .video(url: out, avAsset: AVURLAsset(url: out))
           }

           // Fallback (rare): if no paired video, treat as still photo
           // (existing photo path below)
       }

    if asset.mediaType == .image {
        // Try original photo; fall back to alternate if needed.
        let photoRes = resources.first(where: { $0.type == .photo })
            ?? resources.first(where: { $0.type == .alternatePhoto })
        guard let res = photoRes else { throw NSError(domain: "lp_fetch", code: -10) }
        let url = try await downloadResource(res, ext: "jpg")
        return .photo(url: url)
    } else {
        // Video (original)
        guard let videoRes = resources.first(where: { $0.type == .video }) else {
            throw NSError(domain: "lp_fetch", code: -11)
        }
        let url = try await downloadResource(videoRes, ext: "mov")
        return .video(url: url, avAsset: AVURLAsset(url: url))
    }
}
