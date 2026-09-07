//
//  CollectionsView.swift
//  Snap Second
//
//  Created on 12/29/25.
//

import SwiftUI
import PhosphorSwift
import AVKit
import UniformTypeIdentifiers

struct CollectionsView: View {
    let T: Theme
    let project: Project

    @EnvironmentObject private var clipStore: ClipStore
    @EnvironmentObject private var entitlements: Entitlements
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    // State
    @State private var clips: [Clip] = []
    @State private var showAddSheet = false
    @State private var showPlusMenu = false
    @State private var editMode: EditMode = .inactive
    @State private var selection = Set<Clip.ID>()
    @State private var showMontageView = false
    @State private var showDeleteConfirm = false
    @State private var draggedClip: Clip?
    @State private var showCameraCapture = false
    @State private var capturedVideoURL: URL?
    @State private var showCapturedEditor = false
    @State private var showFullScreenVideo = false
    @State private var fullScreenPlayer: AVPlayer?
    @State private var fullScreenRotation: Double = 0
    @State private var clipToEdit: Clip?
    @State private var clipToDelete: Clip?
    @State private var batchEditingClips: [Clip] = []
    @State private var currentBatchIndex = 0
    @State private var showBatchEditor = false

    // Quick bar spacing
    private let quickBarEstimatedHeight: CGFloat = 64
    private let quickBarBottomPadding: CGFloat = 32
    private let actionButtonsHeight: CGFloat = 54

    // Computed bottom padding based on mode
    private var bottomContentPadding: CGFloat {
        if editMode == .active && !selection.isEmpty {
            return actionButtonsHeight + 16 + quickBarBottomPadding + 20
        } else if editMode == .inactive {
            return quickBarEstimatedHeight + quickBarBottomPadding + 20
        } else {
            return quickBarBottomPadding + 20
        }
    }

    // Layout - matches CalendarView's grid structure
    private var gridColumns: [GridItem] {
        Array(
            repeating: .init(.flexible(), spacing: layoutScale.calendarGridSpacing),
            count: 3 // 3 columns like calendar grid
        )
    }

    // Responsive layout
    private var layoutScale: LayoutScale {
        LayoutScale.forScreenHeight()
    }

    var body: some View {
        mainContent
            .applyNavigationConfiguration()
            .applyToolbars(
                navigationToolbarItems: navigationToolbarItems,
                leadingToolbarItems: leadingToolbarItems,
                toolbarContent: toolbarContent
            )
            .applySheets(
                showAddSheet: $showAddSheet,
                showCameraCapture: $showCameraCapture,
                showMontageView: $showMontageView,
                showCapturedEditor: $showCapturedEditor,
                showFullScreenVideo: $showFullScreenVideo,
                clipToEdit: $clipToEdit,
                addSheetContent: addSheetContent,
                cameraCaptureContent: cameraCaptureContent,
                montageView: montageView,
                capturedEditorContent: capturedEditorContent,
                fullScreenVideoContent: fullScreenVideoContent,
                clipEditorContent: clipEditorContent
            )
            .fullScreenCover(isPresented: $showBatchEditor) {
                batchEditorContent
            }
            .applyAlerts(
                showDeleteConfirm: $showDeleteConfirm,
                clipToDelete: $clipToDelete,
                deleteAlertButtons: deleteAlertButtons,
                deleteAlertMessage: deleteAlertMessage,
                clipStore: clipStore
            )
            .onReceive(NotificationCenter.default.publisher(for: .captureDidProduceURL)) { notification in
                handleCaptureNotification(notification)
            }
            .onAppear {
                // Save this as the last opened project when view appears
                UserDefaults.standard.set(
                    project.id.uuidString,
                    forKey: "lastOpenedProjectID"
                )
            }
            .task { loadClips() }
            .onChange(of: clipStore.clips) { _, _ in loadClips() }
    }

    // MARK: - Body Components

    private var mainContent: some View {
        ZStack {
            T.core.surface
                .ignoresSafeArea()

            contentView
                .overlay(alignment: .bottom) {
                    VStack(spacing: 16) {
                        // Edit/Delete action buttons (shown when clips are selected)
                        if editMode == .active && !selection.isEmpty {
                            actionButtons
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }

                        // Quick bar (hidden in edit mode)
                        if editMode == .inactive {
                            quickBarContainer
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                }
        }
    }

    private var contentView: some View {
        VStack(spacing: 0) {
            if clips.isEmpty {
                emptyState
            } else {
                clipsGrid
            }
        }
    }

    private var quickBarContainer: some View {
        HStack {
            Spacer(minLength: 0)
            quickBar
            Spacer(minLength: 0)
        }
        .zIndex(5)
    }

    @ToolbarContentBuilder
    private var navigationToolbarItems: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            if editMode == .active && !selection.isEmpty {
                Text("\(selection.count) Selected")
                    .font(.system(size: layoutScale.calendarNavTitleSize, weight: .semibold, design: .rounded))
                    .foregroundStyle(T.core.text)
                    .transition(.opacity)
            } else {
                Text(project.name)
                    .font(.system(size: layoutScale.calendarNavTitleSize, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .foregroundStyle(T.core.text)
                    .accessibilityAddTraits(.isHeader)
            }
        }
    }

    @ToolbarContentBuilder
    private var leadingToolbarItems: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button(action: { dismiss() }) {
                Ph.caretLeft.regular
                    .color(T.core.text)
                    .frame(width: layoutScale.calendarBackIconSize, height: layoutScale.calendarBackIconSize)
            }
            .accessibilityLabel("Back to Projects")
        }
    }

    private var addSheetContent: some View {
        NavigationStack {
            LibraryPickerView(project: project, T: T, forEditing: false)
        }
    }

    private var cameraCaptureContent: some View {
        CaptureView(project: project, targetDate: Date())
            .environmentObject(clipStore)
    }

    @ViewBuilder
    private var fullScreenVideoContent: some View {
        if let player = fullScreenPlayer {
            FullScreenVideoView(
                player: player,
                rotationDegrees: fullScreenRotation,
                onClose: {
                    showFullScreenVideo = false
                    fullScreenPlayer = nil
                },
                theme: T
            )
        }
    }

    @ViewBuilder
    private func clipEditorContent(_ clip: Clip) -> some View {
        ClipEditorSheet(
            project: project,
            date: clip.date ?? Date(),
            initialURL: nil,
            editingClip: clip,
            sourceLocalID: clip.sourceLocalID,
            onSave: { url, thumb, duration, start, srcID, rotation, previewFillRaw, scale, offset in
                clipStore.updateClip(
                    clip,
                    withFile: url,
                    thumbnail: thumb,
                    duration: duration,
                    snippetStart: start,
                    sourceLocalID: srcID,
                    rotationDegrees: rotation,
                    previewFillRaw: previewFillRaw,
                    zoomScale: scale,
                    panOffset: (x: Double(offset.x), y: Double(offset.y))
                )
                clipToEdit = nil
            },
            onCancel: { clipToEdit = nil },
            onPerClipCaptionChange: { _ in }
        )
        .presentationBackground(T.core.surface)
    }

    @ViewBuilder
    private var capturedEditorContent: some View {
        if let url = capturedVideoURL {
            ClipEditorSheet(
                project: project,
                date: Date(),
                initialURL: url,
                editingClip: nil,
                sourceLocalID: nil,
                onSave: handleClipEditorSave,
                onCancel: handleClipEditorCancel,
                onPerClipCaptionChange: { _ in }
            )
            .presentationBackground(T.core.surface)
        }
    }

    @ViewBuilder
    private var batchEditorContent: some View {
        if currentBatchIndex < batchEditingClips.count {
            let clip = batchEditingClips[currentBatchIndex]
            ClipEditorSheet(
                project: project,
                date: clip.date ?? Date(),
                initialURL: nil,
                editingClip: clip,
                sourceLocalID: clip.sourceLocalID,
                onSave: handleBatchEditorSave,
                onCancel: handleBatchEditorCancel,
                onPerClipCaptionChange: { _ in }
            )
            .id(clip.id)  // Force SwiftUI to recreate the editor for each clip
            .presentationBackground(T.core.surface)
            .overlay(alignment: .top) {
                // Progress indicator
                if batchEditingClips.count > 1 {
                    Text("\(currentBatchIndex + 1) of \(batchEditingClips.count)")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(T.core.text)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(
                            Capsule()
                                .fill(T.core.surface)
                                .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
                        )
                        .padding(.top, 60)
                }
            }
        }
    }

    @ViewBuilder
    private var deleteAlertButtons: some View {
        Button("Cancel", role: .cancel) { }
        Button("Delete", role: .destructive, action: deleteSelected)
    }

    private var deleteAlertMessage: some View {
        Text("Are you sure you want to delete \(selection.count) clip(s)? This cannot be undone.")
    }

    // MARK: - Handlers

    private func handleClipEditorSave(videoURL: URL, thumb: UIImage, duration: TimeInterval, start: TimeInterval, srcID: String?, rotation: Double, previewFillRaw: String, scale: Double, offset: CGPoint) {
        clipStore.addClip(
            for: Date(),
            project: project,
            fromURL: videoURL,
            thumb: thumb,
            duration: duration,
            isSmartFill: false,
            start: start,
            sourceLocalID: srcID,
            rotationDegrees: rotation,
            previewFillRaw: previewFillRaw,
            zoomScale: scale,
            panOffset: offset
        )
        showCapturedEditor = false
        capturedVideoURL = nil
    }

    private func handleClipEditorCancel() {
        showCapturedEditor = false
        capturedVideoURL = nil
    }

    private func handleCaptureNotification(_ notification: Notification) {
        guard let url = notification.userInfo?["url"] as? URL else { return }
        capturedVideoURL = url
        showCapturedEditor = true
    }

    // MARK: - Subviews

    private var emptyState: some View {
        ScrollView {
            LazyVGrid(columns: gridColumns, spacing: layoutScale.calendarGridSpacing) {
                // Show the "Add" cell in the grid
                GeometryReader { geo in
                    AddClipCell(T: T)
                        .frame(width: geo.size.width, height: geo.size.width)
                        .onTapGesture {
                            showAddSheet = true
                        }
                }
                .aspectRatio(1, contentMode: .fit)
            }
            .padding(.horizontal, layoutScale.headerHorizontalPadding)
            .padding(.top, 16)
            .padding(.bottom, bottomContentPadding)
        }
    }

    private var clipsGrid: some View {
        ScrollView {
            LazyVGrid(columns: gridColumns, spacing: layoutScale.calendarGridSpacing) {
                // Existing clips
                ForEach(clips) { clip in
                    GeometryReader { geo in
                        CollectionClipCard(
                            clip: clip,
                            T: T,
                            isSelected: selection.contains(clip.id),
                            editMode: editMode,
                            onTap: { handleClipTap(clip) },
                            onLongPress: { handleClipLongPress(clip) },
                            onEdit: { clipToEdit = clip },
                            onDelete: { clipToDelete = clip }
                        )
                        .frame(width: geo.size.width, height: geo.size.width)
                        .onDrag {
                            self.draggedClip = clip
                            let uuidString = clip.id?.uuidString ?? UUID().uuidString
                            return NSItemProvider(object: uuidString as NSString)
                        }
                        .onDrop(of: [.text], delegate: ClipDropDelegate(
                            clip: clip,
                            clips: $clips,
                            draggedClip: $draggedClip,
                            onReorder: saveClipOrder
                        ))
                    }
                    .aspectRatio(1, contentMode: .fit)
                }

                // Add cell: appears after existing clips
                GeometryReader { geo in
                    AddClipCell(T: T)
                        .frame(width: geo.size.width, height: geo.size.width)
                        .onTapGesture {
                            showAddSheet = true
                        }
                }
                .aspectRatio(1, contentMode: .fit)
            }
            .padding(.horizontal, layoutScale.headerHorizontalPadding)
            .padding(.top, 16) // Space from navigation bar
            .padding(.bottom, bottomContentPadding) // Dynamic space based on what's showing
        }
    }

    // MARK: - Quick Bar

    private var montageSymbol: String {
        "play.fill"
    }

    @ViewBuilder
    private var actionButtons: some View {
        HStack(spacing: 16) {
            // Edit button (enabled when 1 or more clips are selected)
            Button {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                startBatchEditing()
            } label: {
                HStack(spacing: 8) {
                    Ph.pencilSimple.bold
                        .color(.white)
                        .frame(width: 20, height: 20)
                    Text("Edit")
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(T.core.primary)
                )
            }

            // Delete button
            Button {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                showDeleteConfirm = true
            } label: {
                HStack(spacing: 8) {
                    Ph.trash.bold
                        .color(.white)
                        .frame(width: 20, height: 20)
                    Text("Delete")
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.red)
                )
            }
        }
        .padding(.horizontal, 24)
        .shadow(color: .black.opacity(0.15), radius: 10, y: 5)
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

            // RIGHT — Play Montage
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
                showMontageView = true
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, quickBarBottomPadding)
    }

    @ViewBuilder
    private var plusMenu: some View {
        HStack(spacing: 20) {
            // Camera capture
            Button {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                    showPlusMenu = false
                }
                showCameraCapture = true
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

                    Text("Camera")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(T.core.text)
                }
            }

            // Library import
            Button {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                    showPlusMenu = false
                }
                showAddSheet = true
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

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button(editMode == .active ? "Done" : "Select") {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if editMode == .active {
                        editMode = .inactive
                        selection.removeAll()
                    } else {
                        editMode = .active
                    }
                }
            }
            .font(.system(size: 17, weight: .semibold, design: .rounded))
            .foregroundStyle(T.core.accent)
        }
    }

    @ViewBuilder
    private var montageView: some View {
        // For collections projects, hide the range feature since we want to show all clips
        MontageView(project: project, T: T, hideRangeFeature: true)
    }

    // MARK: - Actions

    private func loadClips() {
        clips = clipStore.clips
            .filter { $0.projectID == project.id }
            .sorted { (clip1, clip2) in
                // Sort by orderIndex (user-defined order)
                let index1 = clip1.orderIndex
                let index2 = clip2.orderIndex

                if index1 != index2 {
                    return index1 < index2
                }

                // Fall back to date sorting if orderIndex is the same
                switch (clip1.date, clip2.date) {
                case (let date1?, let date2?):
                    return date1 < date2
                case (nil, _):
                    return false
                case (_, nil):
                    return true
                }
            }
    }

    private func handleClipTap(_ clip: Clip) {
        if editMode == .active {
            toggleSelection(clip.id)
        } else {
            // Open full-screen video player
            let url = clipStore.urlForClip(clip)
            fullScreenPlayer = AVPlayer(url: url)
            fullScreenRotation = clip.rotationDegrees
            showFullScreenVideo = true
        }
    }

    private func handleClipLongPress(_ clip: Clip) {
        if editMode == .inactive {
            // Enter edit mode and select this clip
            withAnimation(.easeInOut(duration: 0.2)) {
                editMode = .active
                selection.insert(clip.id)
            }
        }
    }

    private func toggleSelection(_ id: Clip.ID) {
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
        }
    }

    private func deleteSelected() {
        for id in selection {
            if let clip = clips.first(where: { $0.id == id }) {
                clipStore.deleteClip(clip)
            }
        }
        clips.removeAll { selection.contains($0.id) }
        selection.removeAll()
        editMode = .inactive
    }

    private func startBatchEditing() {
        // Get selected clips in order
        batchEditingClips = clips.filter { selection.contains($0.id) }
        currentBatchIndex = 0

        if !batchEditingClips.isEmpty {
            // Exit edit mode and show the batch editor
            withAnimation(.easeInOut(duration: 0.2)) {
                editMode = .inactive
                selection.removeAll()
            }
            showBatchEditor = true
        }
    }

    private func handleBatchEditorSave(videoURL: URL, thumb: UIImage, duration: TimeInterval, start: TimeInterval, srcID: String?, rotation: Double, previewFillRaw: String, scale: Double, offset: CGPoint) {
        guard currentBatchIndex < batchEditingClips.count else { return }

        let clip = batchEditingClips[currentBatchIndex]
        clipStore.updateClip(
            clip,
            withFile: videoURL,
            thumbnail: thumb,
            duration: duration,
            snippetStart: start,
            sourceLocalID: srcID,
            rotationDegrees: rotation,
            previewFillRaw: previewFillRaw,
            zoomScale: scale,
            panOffset: (x: Double(offset.x), y: Double(offset.y))
        )

        // Move to next clip or finish
        currentBatchIndex += 1
        if currentBatchIndex >= batchEditingClips.count {
            // Done with all clips
            showBatchEditor = false
            batchEditingClips.removeAll()
            currentBatchIndex = 0
        }
    }

    private func handleBatchEditorCancel() {
        showBatchEditor = false
        batchEditingClips.removeAll()
        currentBatchIndex = 0
    }

    private func saveClipOrder() {
        // Update the orderIndex property for each clip based on their position
        for (index, clip) in clips.enumerated() {
            clip.orderIndex = Int32(index)
        }

        // Save to Core Data
        do {
            try clipStore.container.viewContext.save()
        } catch {
            print("[CollectionsView] Failed to save clip order:", error)
        }
    }
}

// MARK: - Drop Delegate

struct ClipDropDelegate: DropDelegate {
    let clip: Clip
    @Binding var clips: [Clip]
    @Binding var draggedClip: Clip?
    let onReorder: () -> Void

    func performDrop(info: DropInfo) -> Bool {
        draggedClip = nil
        return true
    }

    func dropEntered(info: DropInfo) {
        guard let draggedClip = draggedClip,
              draggedClip.id != clip.id,
              let fromIndex = clips.firstIndex(where: { $0.id == draggedClip.id }),
              let toIndex = clips.firstIndex(where: { $0.id == clip.id }) else {
            return
        }

        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            clips.move(fromOffsets: IndexSet(integer: fromIndex), toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex)
        }

        onReorder()
    }
}

// MARK: - Supporting Views

struct CollectionClipCard: View {
    let clip: Clip
    let T: Theme
    let isSelected: Bool
    let editMode: EditMode
    let onTap: () -> Void
    let onLongPress: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    @Environment(\.colorScheme) private var scheme

    /// Returns the media type of the clip
    private var clipMediaType: ClipMediaType {
        ClipMediaType(rawValue: clip.mediaType) ?? .video
    }

    /// Returns the appropriate icon for the media type badge
    private var mediaTypeBadgeIcon: some View {
        Group {
            switch clipMediaType {
            case .video:
                Ph.videoCamera.fill
                    .color(.white)
                    .frame(width: 12, height: 12)
            case .livePhoto:
                Ph.circlesFour.fill
                    .color(.white)
                    .frame(width: 12, height: 12)
            case .photo:
                Ph.image.fill
                    .color(.white)
                    .frame(width: 12, height: 12)
            }
        }
    }

    var body: some View {
        ZStack {
            // Thumbnail
            if let thumbData = clip.thumbnailData,
               let uiImage = UIImage(data: thumbData) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            } else {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(T.core.surface.opacity(0.3))
                    .overlay {
                        Ph.videoCamera.regular
                            .color(T.textSecondary)
                            .frame(width: 32, height: 32)
                    }
            }

            // Overlays container
            VStack {
                HStack {
                    // Media type badge (bottom-left)
                    Spacer()

                    // Selection indicator (top-right, only in edit mode)
                    if editMode == .active {
                        Circle()
                            .fill(isSelected ? T.core.accent : T.core.surface.opacity(0.9))
                            .frame(width: 32, height: 32)
                            .overlay {
                                if isSelected {
                                    Ph.check.bold
                                        .color(.white)
                                        .frame(width: 18, height: 18)
                                } else {
                                    Circle()
                                        .stroke(T.textSecondary, lineWidth: 2)
                                }
                            }
                            .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .padding(8)

                Spacer()

                HStack {
                    // Media type badge (bottom-left)
                    mediaTypeBadgeIcon
                        .padding(6)
                        .background(
                            Circle()
                                .fill(.black.opacity(0.5))
                        )

                    Spacer()
                }
                .padding(8)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(
                    isSelected ? T.core.accent : T.border.opacity(0.3),
                    lineWidth: isSelected ? 3 : 1
                )
        }
        .shadow(
            color: scheme == .dark ? .black.opacity(0.4) : .black.opacity(0.1),
            radius: isSelected ? 8 : 4,
            y: isSelected ? 4 : 2
        )
        .scaleEffect(isSelected ? 0.97 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isSelected)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: editMode)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .contextMenu {
            Button {
                onEdit()
            } label: {
                Label("Edit Clip", systemImage: "slider.horizontal.3")
            }

            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("Delete Clip", systemImage: "trash")
            }
        }
    }
}

// MARK: - Add Clip Cell

struct AddClipCell: View {
    let T: Theme

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            // Background with subtle gradient
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            T.core.surface,
                            T.core.surface.opacity(0.95)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            // Border
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(T.border.opacity(0.6), lineWidth: 1)

            // Dashed inner border
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .inset(by: 4)
                .stroke(
                    T.border.opacity(0.6),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                )

            // Center content - just the plus icon circle
            Circle()
                .fill(T.core.accent)
                .frame(width: 36, height: 36)
                .overlay {
                    Ph.plus.bold
                        .color(.white)
                        .frame(width: 20, height: 20)
                }
        }
        .shadow(
            color: scheme == .dark ? .black.opacity(0.6) : .black.opacity(0.08),
            radius: 8,
            y: 4
        )
    }
}

// MARK: - View Modifier Extensions
private extension View {
    func applyNavigationConfiguration() -> some View {
        self
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(true)
    }

    func applyToolbars(
        navigationToolbarItems: some ToolbarContent,
        leadingToolbarItems: some ToolbarContent,
        toolbarContent: some ToolbarContent
    ) -> some View {
        self
            .toolbar { navigationToolbarItems }
            .toolbar { leadingToolbarItems }
            .toolbar { toolbarContent }
    }

    func applySheets<AddSheet: View, CameraCapture: View, Montage: View, CapturedEditor: View, FullScreenVideo: View, ClipEditor: View>(
        showAddSheet: Binding<Bool>,
        showCameraCapture: Binding<Bool>,
        showMontageView: Binding<Bool>,
        showCapturedEditor: Binding<Bool>,
        showFullScreenVideo: Binding<Bool>,
        clipToEdit: Binding<Clip?>,
        addSheetContent: AddSheet,
        cameraCaptureContent: CameraCapture,
        montageView: Montage,
        capturedEditorContent: CapturedEditor,
        fullScreenVideoContent: FullScreenVideo,
        clipEditorContent: @escaping (Clip) -> ClipEditor
    ) -> some View {
        self
            .sheet(isPresented: showAddSheet) { addSheetContent }
            .fullScreenCover(isPresented: showCameraCapture) { cameraCaptureContent }
            .fullScreenCover(isPresented: showMontageView) { montageView }
            .fullScreenCover(isPresented: showCapturedEditor) { capturedEditorContent }
            .fullScreenCover(isPresented: showFullScreenVideo) { fullScreenVideoContent }
            .fullScreenCover(item: clipToEdit) { clip in clipEditorContent(clip) }
    }

    func applyAlerts<DeleteButtons: View, DeleteMessage: View>(
        showDeleteConfirm: Binding<Bool>,
        clipToDelete: Binding<Clip?>,
        deleteAlertButtons: DeleteButtons,
        deleteAlertMessage: DeleteMessage,
        clipStore: ClipStore
    ) -> some View {
        self
            .alert("Delete Clips", isPresented: showDeleteConfirm) {
                deleteAlertButtons
            } message: {
                deleteAlertMessage
            }
            .alert("Delete Clip", isPresented: Binding(
                get: { clipToDelete.wrappedValue != nil },
                set: { if !$0 { clipToDelete.wrappedValue = nil } }
            )) {
                Button("Cancel", role: .cancel) { }
                Button("Delete", role: .destructive) {
                    if let clip = clipToDelete.wrappedValue {
                        clipStore.deleteClip(clip)
                    }
                    clipToDelete.wrappedValue = nil
                }
            } message: {
                Text("Are you sure you want to delete this clip? This cannot be undone.")
            }
    }
}
