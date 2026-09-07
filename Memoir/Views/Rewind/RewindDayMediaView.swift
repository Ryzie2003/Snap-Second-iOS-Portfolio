import SwiftUI
import Photos
import AVKit
import PhotosUI

struct RewindDayMediaView: View {
    let asset: PHAsset
    let playPausePing: UUID

    @State private var image: UIImage?
    @State private var player: AVPlayer?
    @State private var livePhoto: PHLivePhoto?

    @State private var isVideoDownloadingFromCloud: Bool = false
    @State private var videoDownloadProgress: Double = 0.0
    @State private var videoRequestID: PHImageRequestID?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if asset.mediaType == .video {
                videoContent
            } else if asset.mediaSubtypes.contains(.photoLive) {
                livePhotoContent
            } else {
                photoContent
            }
        }
        .onAppear { loadAsset() }
        .onDisappear {
            player?.pause()
            if let requestID = videoRequestID {
                PHImageManager.default().cancelImageRequest(requestID)
                videoRequestID = nil
            }
        }
        .onChange(of: playPausePing) { _ in
            // Only respond if this asset is a video
            guard asset.mediaType == .video, let player else { return }

            if player.timeControlStatus == .playing {
                player.pause()
            } else {
                player.play()
            }
        }
    }


    // MARK: - Photo
    private var photoContent: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()  // <- show entire photo
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)  // black bars where needed
            } else {
                ProgressView().tint(.white)
            }
        }
    }

    // MARK: - Video
    private var videoContent: some View {
        ZStack {
            // Background: either player (when ready) or thumbnail (while loading)
            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
            } else if let image {
                // Thumbnail / preview frame while video downloads
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
            } else {
                Color.black.ignoresSafeArea()
            }

            // Overlay loading / progress if player isn't ready yet
            if player == nil {
                if isVideoDownloadingFromCloud {
                    VStack(spacing: 8) {
                        ProgressView(value: videoDownloadProgress)
                            .progressViewStyle(CircularProgressViewStyle())
                            .tint(.white)
                            .frame(width: 32, height: 32)

                        Text("Downloading…")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundColor(.white.opacity(0.8))
                    }
                } else {
                    ProgressView()
                        .tint(.white)
                        .frame(width: 24, height: 24)
                }
            }
        }
    }


    // MARK: - Live Photo
    private var livePhotoContent: some View {
        Group {
            if let livePhoto {
                LivePhotoView(livePhoto: livePhoto)
                    .ignoresSafeArea()
            } else {
                ProgressView().tint(.white)
            }
        }
    }

    private func loadAsset() {
        let manager = PHImageManager.default()

        // Request a still image for both photos AND videos.
        // For videos: this gives us a thumbnail/preview frame.
        let imageOptions = PHImageRequestOptions()
        imageOptions.isNetworkAccessAllowed = true
        imageOptions.resizeMode = .fast

        let targetSize = UIScreen.main.bounds.size * UIScreen.main.scale

        manager.requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: .aspectFit,
            options: imageOptions
        ) { result, _ in
            DispatchQueue.main.async {
                self.image = result
            }
        }

        // Additional handling for video: request AVAsset with iCloud download + progress.
        if asset.mediaType == .video {
            let videoOptions = PHVideoRequestOptions()
            videoOptions.isNetworkAccessAllowed = true
            videoOptions.deliveryMode = .automatic

            videoOptions.progressHandler = { progress, error, stop, info in
                DispatchQueue.main.async {
                    self.isVideoDownloadingFromCloud = progress < 1.0
                    self.videoDownloadProgress = progress
                }
            }

            let requestID = manager.requestAVAsset(forVideo: asset, options: videoOptions) { avAsset, _, _ in
                DispatchQueue.main.async {
                    self.isVideoDownloadingFromCloud = false
                    self.videoDownloadProgress = 1.0

                    if let urlAsset = avAsset as? AVURLAsset {
                        let playerItem = AVPlayerItem(url: urlAsset.url)
                        let player = AVPlayer(playerItem: playerItem)
                        player.actionAtItemEnd = .pause
                        player.isMuted = false
                        self.player = player
                        player.play()
                    }
                }
            }

            self.videoRequestID = requestID
            return
        }

        // Live Photo handling stays as-is
        if asset.mediaSubtypes.contains(.photoLive) {
            let liveOpts = PHLivePhotoRequestOptions()
            liveOpts.isNetworkAccessAllowed = true

            manager.requestLivePhoto(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFit,
                options: liveOpts
            ) { live, _ in
                DispatchQueue.main.async {
                    self.livePhoto = live
                }
            }

            return
        }

        // Regular photos are already handled by the requestImage above.
    }

}

// Helper to multiply CGSize by CGFloat
fileprivate extension CGSize {
    static func * (lhs: CGSize, rhs: CGFloat) -> CGSize {
        return CGSize(width: lhs.width * rhs, height: lhs.height * rhs)
    }
}
