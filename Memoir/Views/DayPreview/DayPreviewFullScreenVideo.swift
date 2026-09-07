//
//  DayPreviewFullScreenVideo.swift
//  Snap Second
//
//  Full-screen video player for DayPreviewView
//

import SwiftUI
import AVFoundation

// MARK: - Full Screen Video View

struct FullScreenVideoView: View {
    let player: AVPlayer?
    let rotationDegrees: Double  // ✅ Add rotation parameter
    var onClose: () -> Void
    let theme: Theme

    @State private var showOverlay: Bool = false
    @State private var endObserver: NSObjectProtocol? = nil

    private func playFromStartIfEnded(_ p: AVPlayer) {
        if let item = p.currentItem {
            let end = item.duration.seconds
            let here = p.currentTime().seconds
            if end.isFinite, here >= end - 0.05 {
                p.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
            }
        }
        p.play()
        showOverlay = false
    }

    private func togglePlayPause(for p: AVPlayer) {
        switch p.timeControlStatus {
        case .playing:
            p.pause()
            showOverlay = true
        default:
            playFromStartIfEnded(p)
        }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let p = player {
                PlayerFillView(player: p, gravity: .resizeAspect)
                    .rotationEffect(.degrees(rotationDegrees))  // ✅ Apply rotation
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        togglePlayPause(for: p)
                    }
                    .onAppear {
                        p.actionAtItemEnd = .pause
                        p.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
                        p.play()
                        showOverlay = false

                        if let eo = endObserver {
                            NotificationCenter.default.removeObserver(eo)
                            endObserver = nil
                        }
                        endObserver = NotificationCenter.default.addObserver(
                            forName: .AVPlayerItemDidPlayToEndTime,
                            object: p.currentItem,
                            queue: .main
                        ) { _ in
                            showOverlay = true
                        }
                    }
                    .onDisappear {
                        p.pause()
                        p.seek(to: .zero)
                        if let eo = endObserver {
                            NotificationCenter.default.removeObserver(eo)
                            endObserver = nil
                        }
                    }

                if showOverlay {
                    Button {
                        playFromStartIfEnded(p)
                    } label: {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 64))
                            .foregroundStyle(theme.core.accent)
                            .shadow(radius: 4, y: 2)
                            .accessibilityLabel("Play")
                    }
                }
            } else {
                ProgressView().tint(.white)
            }

            VStack {
                HStack {
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .bold))
                            .padding(10)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .padding(.top, 16)
                    .padding(.trailing, 16)
                }
                Spacer()
            }
        }
    }
}
