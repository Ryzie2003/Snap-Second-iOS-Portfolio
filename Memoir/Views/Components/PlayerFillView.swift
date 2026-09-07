//
//  PlayerFillView.swift
//  Memoir
//
//  Created by Ryan Zheng on 8/14/25.
//


import SwiftUI
import AVKit
import UIKit

// PlayerFillView.swift
struct PlayerFillView: UIViewRepresentable {
    var player: AVPlayer?
    var gravity: AVLayerVideoGravity = .resizeAspectFill
    func makeUIView(context: Context) -> AVPlayerFillContainer {
        let v = AVPlayerFillContainer()
        v.backgroundColor = .clear
        v.playerLayer.videoGravity = gravity
        v.playerLayer.player = player
        return v
    }
    func updateUIView(_ uiView: AVPlayerFillContainer, context: Context) {
        uiView.playerLayer.videoGravity = gravity
        uiView.playerLayer.player = player
    }
}
final class AVPlayerFillContainer: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}
