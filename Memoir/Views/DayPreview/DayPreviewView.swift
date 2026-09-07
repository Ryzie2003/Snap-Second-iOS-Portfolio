//
//  DayPreviewView.swift
//  Memoir
//
//  Created by Ryan Zheng on 8/11/25.
//
//  Supporting files:
//  - DayPreviewHelpers.swift: EditorItem, PreviewFill, MediaPayload, fetchForEditing
//  - DayPreviewSuggestions.swift: SuggestionTileButton component
//  - DayPreviewJournal.swift: JournalEditorView
//  - DayPreviewFullScreenVideo.swift: FullScreenVideoView

import SwiftUI
import CoreData
import Photos
import PhotosUI
import AVFoundation
import UniformTypeIdentifiers
import RiveRuntime
import PhosphorSwift
import Speech

struct DayPreviewView: View {
    let project: Project
    let date: Date
    @Binding var isClipBarInteracting: Bool

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: ClipStore

    // Saved clips & selection
    @State private var clips: [Clip] = []
    @State private var current: Clip? = nil
    @State private var previewPlayer: AVPlayer? = nil
    @State private var showPreviewPlayOverlay = true

    // Suggestions
    @State private var suggestions: [(asset: PHAsset, label: String, localID: String)] = []
    @State private var suggestionsLoaded = false

    // Editor sheet
    @State private var showEditor = false
    @State private var editorInitialURL: URL? = nil
    @State private var editorEditingClip: Clip? = nil
    @State private var editorSourceLocalID: String? = nil
    @State private var editorIdentity = UUID()
    @State private var _pendingCaptionTextForEditor: String? = nil
    @State private var showFullScreenVideo = false
    @State private var showMoveClipSheet = false
    @State private var moveClipDate = Date()
    @State private var clipToMove: Clip? = nil

    // Custom library picker (for empty-day CTA)
    @State private var showLibraryPicker = false

    // Add-new flow (when day already has clips)
    @State private var showAddPicker = false

    // System camera capture
    @State private var showCapture = false
    @State private var didLaunchCapture = false  // Track if THIS view launched capture
    @State private var capturedURLBuffer: URL? = nil

    @State private var previewFill: PreviewFill = .portrait
    @State private var previewAR: CGFloat = 9.0/16.0  // default

    // Manage (select/delete) mode
    @State private var isManaging = false
    @State private var selection = Set<NSManagedObjectID>()
    private let cellW: CGFloat = 96

    // Day journaling
    @State private var journalText: String = ""
    @ObservedObject private var journalStore = JournalStore.shared
    @State private var showJournalEditor: Bool = false

    private var clipsBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            previewSection
            savedStripHeader
            savedStrip
        }
    }

    private var journalSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Tile {
                Button {
                    showJournalEditor = true
                } label: {
                    ZStack {
                        // Card background
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(T.core.surface)                 // whatever theme you're using
                            .shadow(color: .black.opacity(0.05), radius: 2, y: 1)

                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 8) {
                                Ph.pencilSimpleLine.regular
                                    .frame(width: 17, height: 17)
                                    .foregroundStyle(T.textSecondary.opacity(0.85))

                                Text(journalText.isEmpty ? "What are you grateful for today?" : journalText)
                                    .font(.system(size: 16, weight: .regular, design: .rounded))
                                    .foregroundStyle(journalText.isEmpty ? T.textSecondary : T.core.text)
                                    .lineLimit(3)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(.vertical, 30)
                        .padding(.horizontal, 18)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.bottom, 8)
    }




    @Environment(\.colorScheme) private var scheme
    private var T: Theme { AppTheme.sunsetGlow.theme(for: scheme) }

    private var previewAspectLabel: String {
        let ar = previewAR
        if abs(ar - 1.0) < 0.02 { return "1×1" }
        return ar > 1 ? "Landscape" : "Portrait"
    }

    private func configurePreviewAR(from url: URL) {
        let av = AVURLAsset(url: url)
        Task {
            if let track = try? await av.loadTracks(withMediaType: .video).first,
               let n = try? await track.load(.naturalSize),
               let t = try? await track.load(.preferredTransform) {
                let r = CGRect(origin: .zero, size: n).applying(t)
                let w = max(1, abs(r.width)), h = max(1, abs(r.height))
                await MainActor.run { previewAR = w / h }
            }
        }
    }

    // Moved to DayPreviewHelpers.swift
    // - EditorItem, PreviewFill enum

    @State private var activeSuggestionRequestID: PHImageRequestID? = nil
    @State private var activeSuggestionResourceRequestID: PHAssetResourceDataRequestID? = nil

    private func cancelActiveSuggestionDownload() {
        if let rid = activeSuggestionRequestID {
            PHImageManager.default().cancelImageRequest(rid)
            activeSuggestionRequestID = nil
        }
        if let rid = activeSuggestionResourceRequestID {
            PHAssetResourceManager.default().cancelDataRequest(rid)
            activeSuggestionResourceRequestID = nil
        }
    }

    private struct EditorItem: Identifiable {
        let id = UUID()
        let initialURL: URL?
        let editingClip: Clip?
        let sourceLocalID: String?
    }

    @State private var editorItem: EditorItem? = nil

    private func deleteCurrentClip() {
        guard let c = current else { return }
        store.deleteClip(c)
        Task { await loadState(reset: false) }
    }

    private func presentEditorForEditing() {
        guard let c = current else { return }
        editorItem = EditorItem(
            initialURL: nil,
            editingClip: c,
            sourceLocalID: c.sourceLocalID    // ✅ pass through original asset ID
        )
    }

    private func presentMoveClipSheet(for clip: Clip?) {
        guard let clip else { return }
        clipToMove = clip
        moveClipDate = clip.date ?? date
        showMoveClipSheet = true
    }

    // Moved to DayPreviewHelpers.swift
    // - EditorItem, PreviewFill enum

    var body: some View {
        ZStack {
            T.core.surface.ignoresSafeArea()
            ScrollView {
                VStack {  // outer container so we can center the "page"
                    VStack(spacing: 16) {
                        header
                            .padding(.top, 12)

                        if clips.isEmpty {
                            VStack(spacing: 12) {
    //                            emptyBanner
                                if Calendar.current.isDateInToday(date) {
                                    captureCTA
                                }
                                suggestionsSection
                            }
                        } else {
                            clipsBlock
                        }

                        journalSection

                        Spacer(minLength: 12)
                    }
                    .padding(.bottom, 24)
                    .frame(maxWidth: 520)      // ← center column width for a "page" feel
                    .padding(.horizontal, 16)  // ← side margins on all devices
                }
                .frame(maxWidth: .infinity)     // ← center the column in the scroll view
            }
        }
        .task { await loadState() }
        .task(id: date) {
            journalText = journalStore.text(projectID: project.id, date: date)
            await loadState(reset: true)
        }
        .onReceive(store.$clips) { _ in
            DispatchQueue.main.async {
                Task { await loadState(reset: false) }
            }
        }
        .onChange(of: clips.count) { newCount in
            if newCount == 0 {
                isManaging = false
                selection.removeAll()
            }
        }
        .fullScreenCover(item: $editorItem) { item in
            ClipEditorSheet(
                project: project,
                date: date,
                initialURL: item.initialURL,
                editingClip: item.editingClip,
                sourceLocalID: item.sourceLocalID,
                onSave: { url, thumb, duration, start, srcID, rotation, previewFillRaw, zoomScale, panOffset in
                    if let editing = item.editingClip {
                        store.updateClip(editing,
                                         withFile: url,
                                         thumbnail: thumb,
                                         duration: duration,
                                         snippetStart: start,
                                         sourceLocalID: srcID,
                                         rotationDegrees: rotation,
                                         previewFillRaw: previewFillRaw,
                                         zoomScale: zoomScale,
                                         panOffset: (x: Double(panOffset.x), y: Double(panOffset.y)))
                        if let txt = _pendingCaptionTextForEditor {
                            store.setCaptionText(txt, for: editing)
                        } else {
                            store.setCaptionText(nil, for: editing)
                        }
                    } else {
                        store.addClip(for: date,
                                      project: project,
                                      fromURL: url,
                                      thumb: thumb,
                                      duration: duration,
                                      isSmartFill: false,
                                      start: start,
                                      sourceLocalID: srcID,
                                      rotationDegrees: rotation,
                                      previewFillRaw: previewFillRaw,
                                      zoomScale: zoomScale,
                                      panOffset: panOffset)

                        if let saved = store.clips(for: date, in: project).last {
                            if let txt = _pendingCaptionTextForEditor {
                                store.setCaptionText(txt, for: saved)
                            } else {
                                store.setCaptionText(nil, for: saved)
                            }
                        }
                    }
                    _pendingCaptionTextForEditor = nil
                    Task { await loadState(reset: false) }
                    editorItem = nil
                },
                onCancel: { editorItem = nil },
                onPerClipCaptionChange: { newText in
                    _pendingCaptionTextForEditor = newText
                }
            )
            .id(item.id)
            .presentationBackground(T.core.surface)
        }
        .fullScreenCover(isPresented: $showJournalEditor, onDismiss: {
            journalStore.setText(journalText, projectID: project.id, date: date)
        }) {
            JournalEditorView(text: $journalText, theme: T, date: date)
        }
        .animation(nil, value: date)
        .onDisappear { cancelActiveSuggestionDownload() }
        .sheet(isPresented: $showLibraryPicker) {
            NavigationStack {
                LibraryPickerView(
                    project: project,
                    T: T,
                    forEditing: true,
                    seedDate: Calendar.current.startOfDay(for: date),
                    singleDayOnly: true
                )
            }
        }
        .sheet(isPresented: $showMoveClipSheet) {
            NavigationStack {
                Form {
                    DatePicker(
                        "Move to",
                        selection: $moveClipDate,
                        in: ...Date(),
                        displayedComponents: .date
                    )
                    .font(.system(.body, design: .rounded))
                }
                .scrollContentBackground(.hidden)
                .background(T.core.surface)
                .tint(T.core.accent)
                .navigationTitle("Move Clip")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Move") {
                            if let clip = clipToMove {
                                store.moveClip(clip, to: moveClipDate)
                            }
                            clipToMove = nil
                            showMoveClipSheet = false
                        }
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(T.core.accent)
                    }
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            clipToMove = nil
                            showMoveClipSheet = false
                        }
                        .foregroundStyle(T.textSecondary)
                    }
                }
            }
        }
        .fullScreenCover(isPresented: $showCapture) {
            CaptureView(project: project, targetDate: date)
                .environmentObject(store)
        }
        .onReceive(NotificationCenter.default.publisher(for: .libraryPickerPicked)) { note in
            let localID = note.userInfo?["localIdentifier"] as? String
            let url     = note.userInfo?["url"] as? URL
            showLibraryPicker = false
            editorItem = EditorItem(initialURL: url,
                                    editingClip: nil,
                                    sourceLocalID: localID)
        }
        .onReceive(NotificationCenter.default.publisher(for: .captureDidProduceURL)) { note in
            // Only handle if this view launched the capture
            guard didLaunchCapture else { return }
            guard let url = note.userInfo?["url"] as? URL else { return }
            didLaunchCapture = false
            DispatchQueue.main.async {
                editorItem = EditorItem(initialURL: url, editingClip: nil, sourceLocalID: nil)
            }
        }
        .onChange(of: showCapture) { isShowing in
            if isShowing {
                didLaunchCapture = true
            }
            // Don't reset didLaunchCapture here - the notification arrives async after dismiss
        }
        .fullScreenCover(isPresented: $showFullScreenVideo) {
            FullScreenVideoView(
                player: previewPlayer,
                rotationDegrees: current?.rotationDegrees ?? 0,  // ✅ Pass rotation
                onClose: { showFullScreenVideo = false },
                theme: T
            )
        }
        .animation(nil, value: date)
    }


    // MARK: Header
    private var header: some View {
        VStack(spacing: 4) {
            // Main date line – center, slightly softer than the old 26pt
            Text(date.formatted(date: .abbreviated, time: .omitted))
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .foregroundStyle(T.core.text)

            // Secondary line – clips status
            if !clips.isEmpty {
                Text("\(clips.count) clip\(clips.count == 1 ? "" : "s") today")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(T.textSecondary)
            } else {
                Text("No clips yet")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(T.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)   // center within the page
        .padding(.top, 16)
    }


    private var previewSection: some View {
        VStack(spacing: 10) {
            Tile {
                ZStack {
                    if let p = previewPlayer {
                        // BACKDROP: fill + blur (slightly softened)
                        PlayerFillView(player: p, gravity: .resizeAspectFill)
                            .blur(radius: 18)
                            .saturation(0.9)
                            .brightness(-0.10)
                            .clipped()
                            .rotationEffect(.degrees(current?.rotationDegrees ?? 0))  // ✅ Apply rotation

                        // FOREGROUND: letterboxed fit
                        PlayerFillView(player: p, gravity: .resizeAspect)
                            .id(current?.objectID)
                            .aspectRatio(previewAR, contentMode: .fit)
                            .clipped()
                            .rotationEffect(.degrees(current?.rotationDegrees ?? 0))  // ✅ Apply rotation
                            .overlay(
                                // Softer bottom fade so it feels less “HUD-ish”
                                LinearGradient(
                                    colors: [Color.clear, T.core.surface.opacity(0.18)],
                                    startPoint: .center,
                                    endPoint: .bottom
                                )
                            )
                    } else {
                        // Fallback state
                        Color(T.core.surface)
                        Text("No clip selected")
                            .font(.system(size: 14, weight: .regular, design: .rounded))
                            .foregroundStyle(T.textSecondary)
                    }
                }
            }
            .overlay(alignment: .topTrailing) {
                if current != nil {
                    Menu {
                        Button("Edit Clip", systemImage: "slider.horizontal.3") {
                            presentEditorForEditing()
                        }
                        Button("Move to Date", systemImage: "calendar") {
                            presentMoveClipSheet(for: current)
                        }
                        Button("Delete Clip", systemImage: "trash", role: .destructive) {
                            deleteCurrentClip()
                        }
                    } label: {
                        Ph.dotsThreeOutline.fill
                            .color(.white)
                            .frame(width: 22, height: 22)
                            .padding(10)
                            .shadow(
                                color: scheme == .dark
                                    ? .white.opacity(0.10)
                                    : .black.opacity(0.16),
                                radius: 4, y: 2
                            )
                            .accessibilityLabel("Clip options")
                    }
                    .buttonStyle(.borderless)
                    .padding(.trailing, 24)
                    .padding(.top, 12)
                }
            }
            .frame(height: 260)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(T.border.opacity(0.6), lineWidth: 0.8)
            )
            .shadow(
                color: scheme == .dark
                    ? .white.opacity(0.04)
                    : .black.opacity(0.06),
                radius: 10, y: 4
            )
            .padding(.horizontal, 16)
            .overlay(alignment: .center) {
                if showPreviewPlayOverlay, previewPlayer != nil {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 52))
                        .foregroundStyle(T.core.accent)
                        .shadow(radius: 3, y: 2)
                }
            }
            .animation(nil, value: current?.objectID)
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: 8) {
                    Label(previewAspectLabel, systemImage: "rectangle.and.pencil.and.ellipsis")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: Capsule())

                    if let d = current?.duration {
                        Label(String(format: "%.1fs", d), systemImage: "clock")
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                }
                .padding(.leading, 22)
                .padding(.bottom, 16)
            }
            .onTapGesture {
                guard previewPlayer != nil else { return }
                showFullScreenVideo = true
            }
            .contextMenu {
                if current != nil {
                    Button("Edit Clip", systemImage: "slider.horizontal.3") {
                        presentEditorForEditing()
                    }
                    Button("Move to Date", systemImage: "calendar") {
                        presentMoveClipSheet(for: current)
                    }
                    Button("Delete Clip", systemImage: "trash", role: .destructive) {
                        deleteCurrentClip()
                    }
                }
            }
        }
    }


    // Large square CTA shown when the day is empty
    private var captureCTA: some View {
        Button {
            showCapture = true
        } label: {
            ZStack {
                // Same sizing/shape as the preview card
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(T.core.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(T.border, lineWidth: 1)
                    )
                VStack(spacing: 8) {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 48, weight: .semibold))
                        .foregroundStyle(T.textSecondary)
                    Text("Capture photo or video")
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .foregroundStyle(T.textSecondary)
                }
            }
            .frame(height: 280)
            .padding(.horizontal, 16)
            .shadow(color: scheme == .dark ? .white.opacity(0.06) : .black.opacity(0.08),
                    radius: 10, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Capture photo or video")
    }

    private var savedStripHeader: some View {
        HStack(spacing: 8) {
            Text("Saved clips")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(T.textSecondary)

            Spacer()
        }
        .padding(.horizontal, 16)
    }

    private var savedStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(Array(clips.enumerated()), id: \.1.objectID) { idx, clip in
                    let isSelected = (clip.objectID == current?.objectID)
                    let thumbData = clip.thumbnailData
                    let thumb = thumbData.flatMap(UIImage.init(data:)) ?? UIImage()
                    let _ = idx == 0 ? print("🖼️ [DayPreview] First clip thumbnail: dataSize=\(thumbData?.count ?? 0) bytes, imageSize=\(thumb.size), isSmartFill=\(clip.isSmartFill)") : ()

                    Button {
                        current = clip

                        let url = store.urlForClip(clip)

                        // update AR
                        configurePreviewAR(from: url)

                        // install new player — same pattern as loadState()
                        previewPlayer?.pause()
                        previewPlayer = nil
                        showPreviewPlayOverlay = true

                        DispatchQueue.main.async {
                            previewPlayer = AVPlayer(url: url)
                        }
                    } label: {
                        ZStack {
                            Image(uiImage: thumb)
                                .resizable()
                                .scaledToFill()
                                .frame(width: cellW, height: cellW)
                                .rotationEffect(.degrees(clip.rotationDegrees))  // ✅ Apply rotation to thumbnail
                                .clipped()
                                .cornerRadius(12)

                            if isSelected {
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(T.core.accent.opacity(0.95), lineWidth: 1.6)
                                    .shadow(
                                        color: T.core.accent.opacity(0.25),
                                        radius: 6, y: 3
                                    )
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 2)
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !isClipBarInteracting {
                        isClipBarInteracting = true
                    }
                }
                .onEnded { _ in
                    isClipBarInteracting = false
                }
        )
        .onDisappear {
            isClipBarInteracting = false
        }
    }

    private var suggestionsSection: some View {
        VStack(alignment: .leading, spacing: 14) {

            if !suggestionsLoaded {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Finding suggestions…")
                        .font(.system(size: 14, weight: .regular, design: .rounded))
                        .foregroundStyle(T.textSecondary)
                    Spacer()
                }
            } else if suggestions.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                    Text("No suggestions available")
                        .font(.system(size: 14, weight: .regular, design: .rounded))
                        .foregroundStyle(T.textSecondary)
                    Spacer()
                }
            } else {
                // Today first (up to 6)
                if !todaySuggestions.isEmpty {
                    Text("Suggestions from today")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(T.textSecondary)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(todaySuggestions.prefix(6), id: \.localID) { item in
                                suggestionCell(item)
                            }
                        }
                    }
                }

                // Nearby only if TODAY had none
                if todaySuggestions.isEmpty, !nearbySuggestions.isEmpty {
                    Text("Nearby days")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(T.textSecondary)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(nearbySuggestions.prefix(6), id: \.localID) { item in
                                suggestionCell(item, showDateLabel: true)
                            }
                        }
                    }
                }
            }
        }
    }


     // Split suggestions so UI stays clear
     private var todaySuggestions: [(asset: PHAsset, label: String, localID: String)] {
         suggestions.filter { $0.label == "Today" }
     }
     private var nearbySuggestions: [(asset: PHAsset, label: String, localID: String)] {
         suggestions.filter { $0.label.hasPrefix("Nearby") }
     }

    @ViewBuilder
    private func suggestionCell(
        _ item: (asset: PHAsset, label: String, localID: String),
        showDateLabel: Bool = false
    ) -> some View {
        SuggestionTileButton(
            asset: item.asset,
            label: showDateLabel ? item.label.replacingOccurrences(of: "Nearby · ", with: "") : nil,
            T: T,
            onReady: { payload in
                cancelActiveSuggestionDownload()
                switch payload {
                case .video(let url, _):
                    editorItem = EditorItem(
                        initialURL: url,
                        editingClip: nil,
                        sourceLocalID: item.localID
                    )
                case .photo(let url):
                    editorItem = EditorItem(
                        initialURL: url,
                        editingClip: nil,
                        sourceLocalID: item.localID
                    )
                }
            },
            onRequestID: { rid in activeSuggestionRequestID = rid },
            onResourceRequestID: { rid in activeSuggestionResourceRequestID = rid },
            onCancelActive: { cancelActiveSuggestionDownload() }
        )

    }

    // SuggestionTileButton moved to DayPreviewSuggestions.swift
    /*
    private struct SuggestionTileButton: View {
        let asset: PHAsset
        let label: String?
        let T: Theme
        let onReady: (MediaPayload) -> Void
        let onInstantOpen: (String) -> Void
        let onRequestID: (PHImageRequestID) -> Void
        let onCancelActive: () -> Void

        @State private var downloading = false
        @State private var progress: Double = 0

        @State private var isInCloud: Bool? = nil


        var body: some View {
            Button {
                guard !downloading else { return }
                onCancelActive()

                // Instant-open path for LOCAL photo / Live Photo (no HUD, no await)
                if isInCloud == false && (asset.mediaType == .image || asset.mediaSubtypes.contains(.photoLive)) {
                    onInstantOpen(asset.localIdentifier)
                    return
                }
                // iCloud (or unknown that turns into network fetch) → show HUD when needed
                if isInCloud == true { downloading = true }
                Task {
                    do {
                        let payload = try await fetchForEditing(asset: asset,
                            onProgress: { p in
                            progress = p
                            // If Photos starts reporting progress, we know it's a network fetch → show HUD
                            if !downloading { downloading = true }
                       },
                       onRequestID: { rid in onRequestID(rid) }
                   )
                        downloading = false

                        // Open editor immediately with the file URL we just prepared
                        switch payload {
                        case .photo(let url), .video(let url, _):
                            onReady(payload)   // your onReady sets editorItem with initialURL
                        }
                    } catch {
                        downloading = false
                        // Optional: toast("Couldn't prepare media")
                    }
                }
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    // Thumbnail as a soft photo card
                    AssetThumbnailView(asset: asset)
                        .frame(width: 160, height: 160)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(T.border.opacity(0.65), lineWidth: 0.9)
                        )
                        .shadow(
                            color: T.core.text.opacity(0.10),
                            radius: 8,
                            y: 4
                        )
                        // media-type badge (existing):
                        .overlay(alignment: .bottomTrailing) {
                            DayPreviewView.suggestionTypeBadge(for: asset)
                        }
                        // progress (existing):
                        .overlay {
                            if downloading { progressOverlay }
                        }
                        // iCloud glyph when the original is NOT local:
                        .overlay(alignment: .topLeading) {
                            if (isInCloud == true) && !downloading {
                                icloudBadge
                            }
                        }

                    if let label {
                        Text(label)
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(T.textSecondary)
                            .lineLimit(1)
                    }
                }
            }
            .disabled(downloading)
            .buttonStyle(.plain)
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


        private var progressOverlay: some View {
            ZStack {
                // dim tile lightly while downloading
                Color.black.opacity(0.25)
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                // lightweight progress HUD (no cloud icon)
                VStack(spacing: 8) {
                    ProgressView(value: max(0.05, progress)) // avoid looking stuck at 0%
                        .progressViewStyle(.linear)
                        .frame(width: 96)

                    Text("Preparing \(Int(progress * 100))%")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                }
                .padding(10)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
                )
            }
        }

        private func checkCloudStatus() {
            if asset.mediaSubtypes.contains(.photoLive) {
                // LIVE PHOTO: probe without network using a tiny target size
                let o = PHLivePhotoRequestOptions()
                o.isNetworkAccessAllowed = false
                o.deliveryMode = .fastFormat

                let target = CGSize(width: 64, height: 64) // small & cheap
                PHImageManager.default().requestLivePhoto(
                    for: asset,
                    targetSize: target,
                    contentMode: .aspectFit,
                    options: o
                ) { livePhoto, info in
                    let inCloudFlag = (info?[PHImageResultIsInCloudKey] as? Bool) ?? false
                    // If network is disallowed and we can’t get even a tiny Live Photo,
                    // treat it as in iCloud.
                    let isCloud = inCloudFlag || (livePhoto == nil)
                    DispatchQueue.main.async { self.isInCloud = isCloud }
                }
                return
            }

            if asset.mediaType == .image {
                let o = PHImageRequestOptions()
                o.isNetworkAccessAllowed = false
                o.deliveryMode = .fastFormat
                PHImageManager.default().requestImageDataAndOrientation(for: asset, options: o) { data, _, _, info in
                    let inCloud = (info?[PHImageResultIsInCloudKey] as? Bool) ?? (data == nil)
                    DispatchQueue.main.async { self.isInCloud = inCloud }
                }
            } else { // video
                let o = PHVideoRequestOptions()
                o.isNetworkAccessAllowed = false
                o.deliveryMode = .fastFormat
                PHImageManager.default().requestAVAsset(forVideo: asset, options: o) { av, _, info in
                    let inCloud = (info?[PHImageResultIsInCloudKey] as? Bool) ?? (av == nil)
                    DispatchQueue.main.async { self.isInCloud = inCloud }
                }
            }
        }
    }
    */


    // Moved to DayPreviewSuggestions.swift and DayPreviewHelpers.swift
    // MediaKind enum, mediaKind(), suggestionTypeBadge(), badge()


    // MARK: Data
    private func loadState(reset: Bool = false) async {
        if reset {
            suggestionsLoaded = false
            suggestions.removeAll()
            clips.removeAll()
            current = nil
        }

        // ✅ Get clips and verify against badge count
        let fetchedClips = store.clips(for: date, in: project)
        let badgeCount = store.count(forDayKey: Calendar.current.startOfDay(for: date), project: project)

        // ✅ If mismatch detected, just log it - don't delete anything!
        if fetchedClips.count != badgeCount {
            print("⚠️ [DayPreview] Index mismatch detected")
            print("   Badge shows: \(badgeCount) clips")
            print("   Actually found: \(fetchedClips.count) clips")
        }

        clips = fetchedClips

        // Preserve the currently selected clip if possible
        if let selected = current,
           let match = clips.first(where: { $0.objectID == selected.objectID }) {
            current = match
        } else {
            current = clips.first
        }

        // Rebuild player based on current
        previewPlayer = nil
        showPreviewPlayOverlay = true
        if let c = current {
            let url = store.urlForClip(c)
            configurePreviewAR(from: url)
            DispatchQueue.main.async {
                previewPlayer = AVPlayer(url: url)
            }
        }
        if clips.isEmpty { await loadSuggestions() }
    }

    private func loadSuggestions() async {
        suggestionsLoaded = true
        let cal = Calendar.current
        let start = cal.startOfDay(for: date)

        // Build windows: 0d, -1, +1, -2, +2
        let offsets = [0, -1, 1, -2, 2]
        var results: [(PHAsset, String, String)] = []
        let used = store.usedLocalIDs(in: project)

        for off in offsets {
            guard let dayStart = cal.date(byAdding: .day, value: off, to: start),
                  let dayEnd   = cal.date(byAdding: .day, value: 1, to: dayStart) else { continue }

            let opts = PHFetchOptions()
            opts.predicate = NSPredicate(format: "creationDate >= %@ AND creationDate < %@", dayStart as NSDate, dayEnd as NSDate)
            opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]

            let vids = PHAsset.fetchAssets(with: .video, options: opts)
            let imgs = PHAsset.fetchAssets(with: .image, options: opts)

            var bucket: [PHAsset] = []
            vids.enumerateObjects { a, _, _ in bucket.append(a) }
            imgs.enumerateObjects { a, _, _ in bucket.append(a) }

            let label: String = off == 0 ? "Today" : "Nearby · " + dayStart.formatted(date: .abbreviated, time: .omitted)

            for a in bucket {
                let id = a.localIdentifier
                results.append((a, label, id))
                if results.count >= 8 { break }
            }
            if results.count >= 8 { break }
        }

        await MainActor.run {
            self.suggestions = results
        }
    }

    // MARK: Manage helpers
    private func deleteSelection() {
        guard !selection.isEmpty else { return }
        let ids = selection
        for id in ids {
            if let clip = clips.first(where: { $0.objectID == id }) {
                store.deleteClip(clip)
            }
        }
        selection.removeAll()
        Task { await loadState(reset: false) }
    }

    private func stageSuggestionAndEdit(_ asset: PHAsset, localID: String) {
        // For videos we can play the original URL; for photos we'll convert in the editor
        editorSourceLocalID = localID
        if asset.mediaType == .video {
            let opts = PHVideoRequestOptions(); opts.deliveryMode = .highQualityFormat
            PHImageManager.default().requestAVAsset(forVideo: asset, options: opts) { avAsset, _, _ in
                if let urlAsset = avAsset as? AVURLAsset {
                    DispatchQueue.main.async {
                        editorItem = EditorItem(initialURL: urlAsset.url,
                                                editingClip: nil,
                                                sourceLocalID: localID)
                    }
                } else {
                    // Fallback export with proper orientation handling
                    guard let av = avAsset else { return }
                    Task {
                        do {
                            let out = try await self.exportWithOrientation(av)
                            await MainActor.run {
                                editorItem = EditorItem(initialURL: out,
                                                        editingClip: nil,
                                                        sourceLocalID: localID)
                            }
                        } catch {
                            print("[DayPreview] Fallback export failed: \(error)")
                        }
                    }
                }
            }
        } else {
            editorItem = EditorItem(initialURL: nil,
                                           editingClip: nil,
                                           sourceLocalID: localID)
        }
    }

    /// Export a non-URL AVAsset with proper orientation handling to avoid double-rotation bugs.
    private func exportWithOrientation(_ asset: AVAsset) async throws -> URL {
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw NSError(domain: "DayPreview", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "No video track found"])
        }

        let preferredTransform = try await videoTrack.load(.preferredTransform)
        let naturalSize = try await videoTrack.load(.naturalSize)

        // Calculate the render size after applying the transform
        let transformedRect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        let renderSize = CGSize(
            width: abs(transformedRect.width),
            height: abs(transformedRect.height)
        )

        // Create a composition
        let composition = AVMutableComposition()
        guard let compTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw NSError(domain: "DayPreview", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot create composition track"])
        }

        let duration = try await asset.load(.duration)
        try compTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: duration),
            of: videoTrack,
            at: .zero
        )

        // Also copy audio if present
        if let audioTrack = try await asset.loadTracks(withMediaType: .audio).first,
           let compAudio = composition.addMutableTrack(
               withMediaType: .audio,
               preferredTrackID: kCMPersistentTrackID_Invalid
           ) {
            try? compAudio.insertTimeRange(
                CMTimeRange(start: .zero, duration: duration),
                of: audioTrack,
                at: .zero
            )
        }

        // Create video composition to apply the preferredTransform
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compTrack)
        layerInstruction.setTransform(preferredTransform, at: .zero)

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        instruction.layerInstructions = [layerInstruction]

        let videoComposition = AVMutableVideoComposition()
        videoComposition.instructions = [instruction]
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.renderSize = renderSize

        let out = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pick-\(UUID().uuidString).mp4")
        try? FileManager.default.removeItem(at: out)

        guard let exporter = AVAssetExportSession(asset: composition,
                                                  presetName: AVAssetExportPresetHighestQuality) else {
            throw NSError(domain: "DayPreview", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot create export session"])
        }
        exporter.outputURL = out
        exporter.outputFileType = .mp4
        exporter.videoComposition = videoComposition  // ✅ Apply orientation transform

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            exporter.exportAsynchronously {
                if exporter.status == .completed {
                    cont.resume()
                } else {
                    cont.resume(throwing: exporter.error ?? NSError(
                        domain: "DayPreview", code: -4,
                        userInfo: [NSLocalizedDescriptionKey: "Export failed"]))
                }
            }
        }
        return out
    }
}






// MARK: - DayPreviewPager (smooth swipe between days)
struct DayPreviewPager: View {
    @Environment(\.colorScheme) private var scheme
    private var T: Theme { AppTheme.sunsetGlow.theme(for: scheme) }

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: ClipStore
    let project: Project
    let date: Date

    @State private var anchorDate: Date
    @State private var selection: Int = 1
    @State private var pagingLocked = false
    @State private var clipBarInteracting = false

    @State private var showingAddSheet = false
    @State private var showingReorderSheet = false
    @State private var reorderClips: [Clip] = []
    @State private var reorderDraggingID: NSManagedObjectID? = nil

    private let cal = Calendar.current

    init(project: Project, date: Date) {
        self.project = project
        self.date = date
        _anchorDate = State(initialValue: date)
    }

    private var prevDate: Date { cal.date(byAdding: .day, value: -1, to: anchorDate) ?? anchorDate }
    private var nextDate: Date { cal.date(byAdding: .day, value: +1, to: anchorDate) ?? anchorDate }

    private var canGoForwardDay: Bool {
        // Don’t allow swiping past “today”
        let today = cal.startOfDay(for: Date())
        return anchorDate < today
    }

    private var canReorderCurrentDay: Bool {
        store.clips(for: anchorDate, in: project).count > 1
    }

    var body: some View {
        TabView(selection: $selection) {
            DayPreviewView(project: project, date: prevDate, isClipBarInteracting: $clipBarInteracting)
                .tag(0)
                .id(prevDate)   // ensure fresh load per day
            DayPreviewView(project: project, date: anchorDate, isClipBarInteracting: $clipBarInteracting)
                .tag(1)
                .id(anchorDate)
            DayPreviewView(project: project, date: nextDate, isClipBarInteracting: $clipBarInteracting)
                .tag(2)
                .id(nextDate)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .scrollDisabled(clipBarInteracting)
        .background(T.core.surface.ignoresSafeArea())
        .navigationBarBackButtonHidden(true)
        .toolbarBackground(T.core.surface, for: .navigationBar)
        .toolbarBackground(.visible,       for: .navigationBar)
        .toolbarColorScheme(scheme,        for: .navigationBar)
        .toolbar {
            // Back button (existing)
            ToolbarItem(placement: .navigationBarLeading) {
                Button(action: { dismiss() }) {
                    HStack(spacing: 4) {
                        Ph.caretLeft.bold
                            .frame(width: 18, height: 18)
                            .aspectRatio(contentMode: .fit)
                            .color(T.core.text)
                        Text("Calendar")
                            .font(.system(.callout, design: .rounded))
                            .fontWeight(.semibold)
                            .foregroundStyle(T.core.text)
                    }
                }
                .accessibilityLabel("Back to Calendar")
            }

            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 2) {
                    if canReorderCurrentDay {
                        Button {
                            reorderClips = store.clips(for: anchorDate, in: project)
                            showingReorderSheet = true
                        } label: {
                            Ph.arrowsDownUp.bold
                                .frame(width: 20, height: 20)
                                .color(T.core.primary)
                        }
                        .accessibilityLabel("Reorder Clips")
                    }

                    Button {
                        showingAddSheet.toggle()
                    } label: {
                        Ph.images.fill
                            .frame(width: 22, height: 22)
                            .color(T.core.primary)
                    }
                }
            }
        }


        // Thin rule below the nav bar (once, not per-page)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(T.core.text.opacity(0.15))  // or T.border if you have it
                .frame(height: 0.6)
                .ignoresSafeArea()
        }
        // When user swipes to edge page, advance anchor and snap back to center without animating the snap
        .onChange(of: selection) { newValue in
            // Prevent multiple advances from a vigorous swipe
            guard !pagingLocked else {
                withTransaction(Transaction(animation: nil)) { selection = 1 }
                return
            }
            switch newValue {
            case 0: // previous day
                pagingLocked = true
                anchorDate = prevDate
                withTransaction(Transaction(animation: nil)) { selection = 1 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { pagingLocked = false }
            case 2: // next day
                if canGoForwardDay {
                    pagingLocked = true
                    anchorDate = nextDate
                    withTransaction(Transaction(animation: nil)) { selection = 1 }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { pagingLocked = false }
                } else {
                    UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                    withTransaction(Transaction(animation: nil)) { selection = 1 } // bounce back
                }
            default:
                break
            }
        }
        .task(id: anchorDate) {
            // touching the views via ids ensures SwiftUI instantiates neighbors early
            _ = prevDate; _ = nextDate
        }
        // If we’re navigated to a different start date from outside, reset the anchor
        .onChange(of: date) { d in
            anchorDate = d
            withTransaction(Transaction(animation: nil)) { selection = 1 }
        }
        .onAppear {
            // Ensure we start centered; mirrors Calendar pager init
            selection = 1
        }
        .sheet(isPresented: $showingAddSheet) {
            NavigationStack {
                LibraryPickerView(
                    project: project,
                    T: T,
                    forEditing: true,
                    seedDate: anchorDate,
                    singleDayOnly: true
                )
            }
        }
        .sheet(isPresented: $showingReorderSheet) {
            NavigationStack {
                ScrollView {
                    LazyVGrid(columns: [
                        GridItem(.flexible(), spacing: 12),
                        GridItem(.flexible(), spacing: 12)
                    ], spacing: 12) {
                        ForEach(Array(reorderClips.enumerated()), id: \.1.objectID) { idx, clip in
                            pagerReorderTile(for: clip, index: idx + 1)
                        }
                    }
                    .padding(16)
                }
                .background(T.core.surface)
                .navigationTitle("Reorder Clips")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            showingReorderSheet = false
                        }
                        .font(.system(.callout, design: .rounded).weight(.semibold))
                        .foregroundStyle(T.core.text)
                    }
                }
            }
        }

    }

    private func pagerReorderTile(for clip: Clip, index: Int) -> some View {
        let thumbData = clip.thumbnailData
        let thumb = thumbData.flatMap(UIImage.init(data:)) ?? UIImage()
        return ZStack(alignment: .topLeading) {
            Image(uiImage: thumb)
                .resizable()
                .scaledToFill()
                .rotationEffect(.degrees(clip.rotationDegrees))
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipped()
                .cornerRadius(14)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(T.border.opacity(0.5), lineWidth: 0.8)
                )

            Text("\(index)")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(T.core.text)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(8)
        }
        .contentShape(Rectangle())
        .onDrag {
            reorderDraggingID = clip.objectID
            return NSItemProvider(object: clip.objectID.uriRepresentation().absoluteString as NSString)
        }
        .onDrop(of: [.text], delegate: PagerClipReorderDropDelegate(
            item: clip,
            items: $reorderClips,
            draggingID: $reorderDraggingID,
            onReorder: { newOrder in
                store.reorderClips(for: anchorDate, in: project, to: newOrder)
            }
        ))
    }

    private struct PagerClipReorderDropDelegate: DropDelegate {
        let item: Clip
        @Binding var items: [Clip]
        @Binding var draggingID: NSManagedObjectID?
        let onReorder: ([Clip]) -> Void

        func dropEntered(info: DropInfo) {
            guard let draggingID,
                  let fromIndex = items.firstIndex(where: { $0.objectID == draggingID }),
                  let toIndex = items.firstIndex(where: { $0.objectID == item.objectID }),
                  fromIndex != toIndex else { return }

            withAnimation(.spring(response: 0.22, dampingFraction: 0.9)) {
                items.move(fromOffsets: IndexSet(integer: fromIndex),
                           toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex)
            }
        }

        func dropUpdated(info: DropInfo) -> DropProposal? {
            DropProposal(operation: .move)
        }

        func performDrop(info: DropInfo) -> Bool {
            draggingID = nil
            onReorder(items)
            return true
        }
    }
}
