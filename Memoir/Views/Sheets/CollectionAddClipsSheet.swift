//
//  CollectionAddClipsSheet.swift
//  Snap Second
//
//  Created on 12/29/25.
//

import SwiftUI
import PhotosUI
import PhosphorSwift
import AVFoundation

struct CollectionAddClipsSheet: View {
    let T: Theme
    let project: Project
    let onAdd: ([Clip]) -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var clipStore: ClipStore

    @State private var selectedTab: AddClipTab = .fromLibrary
    @State private var photoPickerItems: [PhotosPickerItem] = []
    @State private var isImporting = false
    @State private var importProgress: Double = 0
    @State private var selectedProjectClips: Set<Clip.ID> = []

    enum AddClipTab: String, CaseIterable, Identifiable {
        case fromLibrary = "Library"
        case fromProjects = "Projects"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .fromLibrary: return "photo.on.rectangle.angled"
            case .fromProjects: return "folder"
            }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Tab picker
                Picker("Source", selection: $selectedTab) {
                    ForEach(AddClipTab.allCases) { tab in
                        Label(tab.rawValue, systemImage: tab.icon)
                            .tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding()

                // Content based on tab
                Group {
                    switch selectedTab {
                    case .fromLibrary:
                        fromLibraryView
                    case .fromProjects:
                        fromProjectsView
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationTitle("Add Clips")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }

                if selectedTab == .fromProjects && !selectedProjectClips.isEmpty {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Add (\(selectedProjectClips.count))") {
                            addSelectedProjectClips()
                        }
                    }
                }
            }
            .overlay {
                if isImporting {
                    importingOverlay
                }
            }
        }
    }

    private var fromLibraryView: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(spacing: 16) {
                Ph.image.regular
                    .color(T.core.accent)
                    .frame(width: 64, height: 64)

                Text("Choose from Library")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundStyle(T.core.text)

                Text("Select videos from your photo library to add to this collection")
                    .font(.system(.body, design: .rounded))
                    .foregroundStyle(T.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                PhotosPicker(
                    selection: $photoPickerItems,
                    maxSelectionCount: 20,
                    matching: .videos
                ) {
                    HStack(spacing: 8) {
                        Ph.plus.bold
                            .color(.white)
                            .frame(width: 20, height: 20)
                        Text("Select Videos")
                            .font(.system(.headline, design: .rounded))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(T.core.accent)
                    .clipShape(Capsule())
                    .foregroundStyle(.white)
                    .shadow(color: T.core.accent.opacity(0.3), radius: 12, y: 6)
                }
                .padding(.horizontal, 32)
                .onChange(of: photoPickerItems) { _, newItems in
                    guard !newItems.isEmpty else { return }
                    Task {
                        await importFromPhotos(newItems)
                    }
                }
            }

            Spacer()
        }
    }

    private var fromProjectsView: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                ForEach(availableProjects) { proj in
                    ProjectClipsSection(
                        project: proj,
                        clips: clipsForProject(proj.id),
                        T: T,
                        selection: $selectedProjectClips
                    )
                }
            }
            .padding()
        }
    }

    private var importingOverlay: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                ProgressView(value: importProgress)
                    .progressViewStyle(.linear)
                    .frame(width: 200)
                    .tint(T.core.accent)

                Text("Importing clips...")
                    .font(.system(.subheadline, design: .rounded).weight(.medium))
                    .foregroundStyle(.white)
            }
            .padding(24)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(T.core.surface.opacity(0.95))
            )
            .shadow(radius: 20)
        }
    }

    // MARK: - Helpers

    private var availableProjects: [Project] {
        // Get all projects except the current one
        let allProjects = clipStore.clips
            .compactMap { clip -> UUID? in clip.projectID }
            .reduce(into: Set<UUID>()) { $0.insert($1) }

        // TODO: Get actual project list from ProjectStore
        // For now, just return empty to prevent crashes
        return []
    }

    private func clipsForProject(_ projectID: UUID) -> [Clip] {
        clipStore.clips
            .filter { $0.projectID == projectID }
            .sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
    }

    // MARK: - Actions

    private func importFromPhotos(_ items: [PhotosPickerItem]) async {
        isImporting = true
        importProgress = 0

        var importedClips: [Clip] = []
        let totalItems = Double(items.count)

        for (index, item) in items.enumerated() {
            // Load the video URL
            if let movie = try? await item.loadTransferable(type: VideoTransferable.self) {
                // Create a new clip in the ClipStore
                // The clip will be associated with this project
                if let clip = await createClipFromVideo(movie.url) {
                    importedClips.append(clip)
                }
            }

            importProgress = Double(index + 1) / totalItems
        }

        isImporting = false

        if !importedClips.isEmpty {
            onAdd(importedClips)
        }
    }

    private func createClipFromVideo(_ url: URL) async -> Clip? {
        // Create a clip from the video URL
        // This is a simplified version - in production you'd want more error handling

        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else {
            return nil
        }

        let duration = try? await asset.load(.duration)

        // Generate thumbnail
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let time = CMTime(seconds: 0, preferredTimescale: 600)

        var thumbnailData: Data?
        if let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) {
            let uiImage = UIImage(cgImage: cgImage)
            thumbnailData = uiImage.jpegData(compressionQuality: 0.8)
        }

        // TODO: Use ClipStore to create and persist the clip
        // For now, return nil to avoid crashes
        // The actual implementation would be:
        // return await clipStore.createClip(projectID: project.id, videoURL: url, thumbnail: thumbnailData)

        return nil
    }

    private func addSelectedProjectClips() {
        let clipsToAdd = clipStore.clips.filter { selectedProjectClips.contains($0.id) }

        // TODO: Copy these clips to the current project
        // For now, just callback with empty array
        onAdd([])
        dismiss()
    }
}

// MARK: - Supporting Views

struct ProjectClipsSection: View {
    let project: Project
    let clips: [Clip]
    let T: Theme
    @Binding var selection: Set<Clip.ID>

    private let gridColumns = [
        GridItem(.adaptive(minimum: 100, maximum: 120), spacing: 8)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Project header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name)
                        .font(.system(.headline, design: .rounded))
                        .foregroundStyle(T.core.text)

                    Text("\(clips.count) clip\(clips.count == 1 ? "" : "s")")
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(T.textSecondary)
                }

                Spacer()

                if !clips.isEmpty {
                    Button(action: toggleAllInProject) {
                        Text(allSelected ? "Deselect All" : "Select All")
                            .font(.system(.caption, design: .rounded).weight(.medium))
                            .foregroundStyle(T.core.accent)
                    }
                }
            }

            // Clips grid
            if clips.isEmpty {
                Text("No clips in this project")
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(T.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
            } else {
                LazyVGrid(columns: gridColumns, spacing: 8) {
                    ForEach(clips) { clip in
                        ClipSelectionCard(
                            clip: clip,
                            T: T,
                            isSelected: selection.contains(clip.id)
                        )
                        .onTapGesture {
                            toggleClip(clip.id)
                        }
                    }
                }
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(T.core.surface.opacity(0.5))
        )
    }

    private var allSelected: Bool {
        !clips.isEmpty && clips.allSatisfy { selection.contains($0.id) }
    }

    private func toggleClip(_ id: Clip.ID) {
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
        }
    }

    private func toggleAllInProject() {
        if allSelected {
            // Deselect all from this project
            clips.forEach { selection.remove($0.id) }
        } else {
            // Select all from this project
            clips.forEach { selection.insert($0.id) }
        }
    }
}

struct ClipSelectionCard: View {
    let clip: Clip
    let T: Theme
    let isSelected: Bool

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Thumbnail
            if let thumbData = clip.thumbnailData,
               let uiImage = UIImage(data: thumbData) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(1, contentMode: .fill)
                    .clipped()
            } else {
                Rectangle()
                    .fill(T.core.surface)
                    .aspectRatio(1, contentMode: .fill)
                    .overlay {
                        Ph.videoCamera.regular
                            .color(T.textSecondary)
                            .frame(width: 24, height: 24)
                    }
            }

            // Selection indicator
            Circle()
                .fill(isSelected ? T.core.accent : T.core.surface.opacity(0.9))
                .frame(width: 24, height: 24)
                .overlay {
                    if isSelected {
                        Ph.check.bold
                            .color(.white)
                            .frame(width: 14, height: 14)
                    } else {
                        Circle()
                            .stroke(T.textSecondary, lineWidth: 2)
                    }
                }
                .padding(6)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isSelected ? T.core.accent : .clear, lineWidth: 2)
        }
    }
}

// MARK: - Video Transferable

struct VideoTransferable: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { video in
            SentTransferredFile(video.url)
        } importing: { received in
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent(received.file.lastPathComponent)
            if FileManager.default.fileExists(atPath: copy.path) {
                try FileManager.default.removeItem(at: copy)
            }
            try FileManager.default.copyItem(at: received.file, to: copy)
            return Self(url: copy)
        }
    }
}
