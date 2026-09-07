//
//  ClipPreviewView.swift
//  Snap Second
//
//  Created on 12/29/25.
//

import SwiftUI
import AVKit
import PhosphorSwift

struct ClipPreviewView: View {
    let clip: Clip
    let project: Project
    let T: Theme

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @EnvironmentObject private var clipStore: ClipStore

    @State private var player: AVPlayer?
    @State private var showPlayOverlay = true
    @State private var showFullScreenVideo = false
    @State private var showEditor = false
    @State private var showDeleteConfirm = false

    // Preview aspect ratio
    @State private var previewAR: CGFloat = 9.0/16.0

    private var previewAspectLabel: String {
        let ar = previewAR
        if abs(ar - 1.0) < 0.02 { return "1×1" }
        return ar > 1 ? "Landscape" : "Portrait"
    }

    var body: some View {
        ScrollView {
            VStack {
                VStack(spacing: 16) {
                    header
                        .padding(.top, 12)

                    previewSection

                    Spacer(minLength: 12)
                }
                .padding(.bottom, 24)
                .frame(maxWidth: 520)
                .padding(.horizontal, 16)
            }
            .frame(maxWidth: .infinity)
        }
        .background(T.core.surface)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button(action: { dismiss() }) {
                    HStack(spacing: 4) {
                        Ph.caretLeft.bold
                            .frame(width: 18, height: 18)
                            .color(T.core.text)
                        Text("Back")
                            .font(.system(.callout, design: .rounded))
                            .fontWeight(.semibold)
                            .foregroundStyle(T.core.text)
                    }
                }
                .accessibilityLabel("Back")
            }
        }
        .task {
            loadPlayer()
        }
        .fullScreenCover(isPresented: $showFullScreenVideo) {
            FullScreenVideoView(
                player: player,
                rotationDegrees: clip.rotationDegrees,
                onClose: { showFullScreenVideo = false },
                theme: T
            )
        }
        .fullScreenCover(isPresented: $showEditor) {
            ClipEditorSheet(
                project: project,
                date: clip.date ?? Date(),
                initialURL: nil,
                editingClip: clip,
                sourceLocalID: clip.sourceLocalID,
                onSave: { url, thumb, duration, start, srcID, rotation, previewFillRaw, zoom, offset in
                    clipStore.updateClip(
                        clip,
                        withFile: url,
                        thumbnail: thumb,
                        duration: duration,
                        snippetStart: start,
                        sourceLocalID: srcID,
                        rotationDegrees: rotation,
                        previewFillRaw: previewFillRaw,
                        zoomScale: zoom,
                        panOffset: (x: Double(offset.x), y: Double(offset.y))
                    )
                    showEditor = false
                    loadPlayer()
                },
                onCancel: { showEditor = false },
                onPerClipCaptionChange: { _ in }
            )
            .presentationBackground(T.core.surface)
        }
        .alert("Delete Clip", isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                clipStore.deleteClip(clip)
                dismiss()
            }
        } message: {
            Text("Are you sure you want to delete this clip? This cannot be undone.")
        }
    }

    // MARK: - Header
    private var header: some View {
        VStack(spacing: 4) {
            // Clip name or date
            if let date = clip.date {
                Text(date.formatted(date: .abbreviated, time: .omitted))
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .foregroundStyle(T.core.text)
            } else {
                Text("Clip Preview")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .foregroundStyle(T.core.text)
            }

            // Duration
            if clip.duration > 0 {
                Text(String(format: "%.1f seconds", clip.duration))
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(T.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 16)
    }

    // MARK: - Preview Section
    private var previewSection: some View {
        VStack(spacing: 10) {
            ZStack {
                if let p = player {
                    // BACKDROP: fill + blur
                    PlayerFillView(player: p, gravity: .resizeAspectFill)
                        .blur(radius: 18)
                        .saturation(0.9)
                        .brightness(-0.10)
                        .clipped()
                        .rotationEffect(.degrees(clip.rotationDegrees))

                    // FOREGROUND: letterboxed fit
                    PlayerFillView(player: p, gravity: .resizeAspect)
                        .aspectRatio(previewAR, contentMode: .fit)
                        .clipped()
                        .rotationEffect(.degrees(clip.rotationDegrees))
                        .overlay(
                            LinearGradient(
                                colors: [Color.clear, T.core.surface.opacity(0.18)],
                                startPoint: .center,
                                endPoint: .bottom
                            )
                        )
                } else {
                    Color(T.core.surface)
                    ProgressView()
                        .tint(T.core.accent)
                }
            }
            .overlay(alignment: .topTrailing) {
                Menu {
                    Button("Edit Clip", systemImage: "slider.horizontal.3") {
                        showEditor = true
                    }
                    Button("Delete Clip", systemImage: "trash", role: .destructive) {
                        showDeleteConfirm = true
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
                if showPlayOverlay, player != nil {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 52))
                        .foregroundStyle(T.core.accent)
                        .shadow(radius: 3, y: 2)
                }
            }
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: 8) {
                    Label(previewAspectLabel, systemImage: "rectangle.and.pencil.and.ellipsis")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: Capsule())

                    if clip.duration > 0 {
                        Label(String(format: "%.1fs", clip.duration), systemImage: "clock")
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
                guard player != nil else { return }
                showFullScreenVideo = true
            }
            .contextMenu {
                Button("Edit Clip", systemImage: "slider.horizontal.3") {
                    showEditor = true
                }
                Button("Delete Clip", systemImage: "trash", role: .destructive) {
                    showDeleteConfirm = true
                }
            }
        }
    }

    // MARK: - Actions

    private func loadPlayer() {
        let url = clipStore.urlForClip(clip)

        // Configure aspect ratio
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

        // Create player
        player?.pause()
        player = AVPlayer(url: url)
        showPlayOverlay = true
    }
}
