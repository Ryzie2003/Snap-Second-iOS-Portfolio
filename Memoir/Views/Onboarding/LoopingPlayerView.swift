import SwiftUI
import AVFoundation

/// A CALayer-backed looping player with no playback controls.
struct LoopingPlayerView: UIViewRepresentable {
    let videoName: String
    let videoExt: String
    var isMuted: Bool = false

    // Explicit UIView type for clarity
    typealias UIViewType = PlayerContainer

    // Must NOT be private, otherwise make/update signatures would “use a private type”
    final class PlayerContainer: UIView {
        // Use the view's real backing layer as the player layer
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var queuePlayer: AVQueuePlayer?
        var looper: AVPlayerLooper?

        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .black
            isOpaque = true
            clipsToBounds = true
            playerLayer.backgroundColor = UIColor.black.cgColor
            playerLayer.videoGravity = .resizeAspectFill
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    }

    // OK now: signature uses a non-private type
    func makeUIView(context: Context) -> PlayerContainer {
        let view = PlayerContainer()
        configure(view)
        return view
    }

    func updateUIView(_ uiView: PlayerContainer, context: Context) {
        // Keep player configured on size/trait changes
        configure(uiView)
        uiView.queuePlayer?.isMuted = isMuted
        uiView.queuePlayer?.volume = isMuted ? 0 : 1
    }

    private func configure(_ container: PlayerContainer) {
        guard let url = Bundle.main.url(forResource: videoName, withExtension: videoExt) else {
            // The public portfolio intentionally omits the production onboarding video.
            // Keep the branded overlay usable instead of failing when that asset is absent.
            return
        }

        // Only set up once
        if container.queuePlayer == nil {
            let item = AVPlayerItem(url: url)
            let player = AVQueuePlayer()
            player.automaticallyWaitsToMinimizeStalling = false
            container.queuePlayer = player
            container.looper = AVPlayerLooper(player: player, templateItem: item)

            container.playerLayer.player = player
            player.isMuted = isMuted
            player.volume = isMuted ? 0 : 1
            player.playImmediately(atRate: 1.0)
        }
    }
}
