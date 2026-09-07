import SwiftUI
import PhosphorSwift

struct MusicShelfVertical: View {
    let T: Theme
    let tracks: [Track]
    let freeTrackIDs: Set<String>

    @Binding var selectedTrack: Track?
    @Binding var isUsingCustomAudio: Bool
    @Binding var musicVol: Double
    @Binding var videoVol: Double

    let onChange: () -> Void
    let onPickCustomAudio: () -> Void

    var body: some View {
        let pillWidth: CGFloat = 148
        let interColumnSpacing: CGFloat = 8
        let twoCols = [
            GridItem(.fixed(pillWidth), spacing: interColumnSpacing, alignment: .center),
            GridItem(.fixed(pillWidth), spacing: interColumnSpacing, alignment: .center)
        ]

        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "music.note").foregroundStyle(T.textSecondary).opacity(0.7)
                Slider(value: $musicVol, in: 0...100, step: 1) { editing in
                    if !editing { onChange() }
                }
                Text("\(Int(musicVol))%")
                    .font(.system(.caption, design: .rounded).monospacedDigit())
                    .foregroundStyle(T.textSecondary)
            }

            HStack(spacing: 12) {
                Image(systemName: "video").foregroundStyle(T.textSecondary).opacity(0.7)
                Slider(value: $videoVol, in: 0...100, step: 1) { editing in
                    if !editing { onChange() }
                }
                Text("\(Int(videoVol))%")
                    .font(.system(.caption, design: .rounded).monospacedDigit())
                    .foregroundStyle(T.textSecondary)
            }
        }
        .padding(.top, 6)
        .frame(maxWidth: .infinity)

        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .center, spacing: 12) {
                LazyVGrid(columns: twoCols, alignment: .center, spacing: 10) {
                    PillTextButton(
                        "None",
                        isOn: selectedTrack == nil && !isUsingCustomAudio,
                        T: T
                    ) {
                        selectedTrack = nil
                        isUsingCustomAudio = false
                        onChange()
                    }
                    .frame(width: pillWidth)

                    PillButton(isOn: isUsingCustomAudio, T: T) {
                        HStack(spacing: 6) {
                            Ph.sparkle.fill
                                .foregroundStyle(.yellow)
                                .frame(width: 18, height: 18)
                            Text("My Audio")
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                    } action: {
                        onPickCustomAudio()
                    }
                    .frame(width: pillWidth)

                    ForEach(tracks) { track in
                        PillButton(isOn: selectedTrack == track && !isUsingCustomAudio, T: T) {
                            Text(track.name)
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                                .frame(maxWidth: .infinity, alignment: .center)
                        } action: {
                            if selectedTrack == track && !isUsingCustomAudio {
                                selectedTrack = nil
                            } else {
                                selectedTrack = track
                            }
                            isUsingCustomAudio = false
                            onChange()
                        }
                        .frame(width: pillWidth)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
        }
    }
}
