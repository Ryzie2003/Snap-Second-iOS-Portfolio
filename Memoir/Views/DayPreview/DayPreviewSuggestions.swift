//
//  DayPreviewSuggestions.swift
//  Snap Second
//
//  Suggestions section for DayPreviewView
//

import SwiftUI
import Photos
import AVFoundation

// MARK: - Suggestion Tile Button

struct SuggestionTileButton: View {
    let asset: PHAsset
    let label: String?
    let T: Theme
    let onReady: (MediaPayload) -> Void
    let onRequestID: (PHImageRequestID) -> Void
    let onResourceRequestID: (PHAssetResourceDataRequestID) -> Void
    let onCancelActive: () -> Void

    @State private var downloading = false
    @State private var progress: Double = 0
    @State private var isInCloud: Bool? = nil
    @State private var fetchTask: Task<Void, Never>? = nil

    var body: some View {
        Button {
            guard !downloading else { return }
            onCancelActive()
            fetchTask?.cancel()

            progress = 0.05
            downloading = true
            fetchTask = Task {
                let estimatedProgressTask = Task { @MainActor in
                    let steps = 90
                    let sleep: UInt64 = 250_000_000
                    for step in 1...steps {
                        if Task.isCancelled { return }
                        try? await Task.sleep(nanoseconds: sleep)
                        let t = Double(step) / Double(steps)
                        let eased = t * (2 - t)
                        progress = max(progress, min(0.92, 0.05 + (0.87 * eased)))
                    }
                }
                defer { estimatedProgressTask.cancel() }

                do {
                    let payload = try await withMediaPreparationTimeout {
                        try await fetchForEditing(
                            asset: asset,
                            onProgress: { p in
                                progress = max(progress, min(1, max(0, p)))
                                if !downloading { downloading = true }
                            },
                            onRequestID: { rid in onRequestID(rid) },
                            onResourceRequestID: { rid in onResourceRequestID(rid) }
                        )
                    }
                    guard !Task.isCancelled else { return }
                    progress = 1
                    downloading = false

                    onReady(payload)
                } catch {
                    onCancelActive()
                    downloading = false
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
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
                    .overlay(alignment: .bottomTrailing) {
                        suggestionTypeBadge(for: asset)
                    }
                    .overlay {
                        if downloading { progressOverlay }
                    }
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
        .onDisappear {
            fetchTask?.cancel()
            onCancelActive()
        }
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
            Color.black.opacity(0.25)
                .clipShape(RoundedRectangle(cornerRadius: 16))

            VStack(spacing: 8) {
                ProgressView(value: max(0.05, progress))
                    .progressViewStyle(.linear)
                    .frame(width: 96)

                Text(progressLabel(for: progress))
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

    private func progressLabel(for progress: Double) -> String {
        let clamped = min(1, max(0, progress))
        guard clamped > 0 else { return "Preparing..." }
        return "Preparing \(Int(max(0.05, clamped) * 100))%"
    }

    private func checkCloudStatus() {
        if asset.mediaSubtypes.contains(.photoLive) {
            let o = PHLivePhotoRequestOptions()
            o.isNetworkAccessAllowed = false
            o.deliveryMode = .fastFormat

            let target = CGSize(width: 64, height: 64)
            PHImageManager.default().requestLivePhoto(
                for: asset,
                targetSize: target,
                contentMode: .aspectFit,
                options: o
            ) { livePhoto, info in
                let inCloudFlag = (info?[PHImageResultIsInCloudKey] as? Bool) ?? false
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
        } else {
            let o = PHVideoRequestOptions()
            o.isNetworkAccessAllowed = false
            o.deliveryMode = .fastFormat
            PHImageManager.default().requestAVAsset(forVideo: asset, options: o) { av, _, info in
                let inCloud = (info?[PHImageResultIsInCloudKey] as? Bool) ?? (av == nil)
                DispatchQueue.main.async { self.isInCloud = inCloud }
            }
        }
    }

    private func suggestionTypeBadge(for asset: PHAsset) -> some View {
        switch mediaKind(for: asset) {
        case .video:     return AnyView(badge("video.fill"))
        case .livePhoto: return AnyView(badge("livephoto"))
        case .image:     return AnyView(badge("photo"))
        }
    }

    private func badge(_ system: String) -> some View {
        Image(systemName: system)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white)
            .padding(6)
            .padding(6)
            .allowsHitTesting(false)
    }
}
