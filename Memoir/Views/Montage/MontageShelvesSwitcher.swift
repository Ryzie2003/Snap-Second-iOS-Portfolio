//import SwiftUI
//
//struct MontageShelvesSwitcher: View {
//    let T: Theme
//    @Binding var selectedTab: MontageView.ControlTab
//
//    // NEW: style
//    @Binding var selectedStyle: MontageStyle
//    let onStyleChange: () -> Void
//
//    // Range
//    @Binding var rangeLabel: String
//    let clipCount: Int
//    let onChoosePreset: (Preset) -> Void
//    let onChooseAll: () -> Void
//    @Binding var showCustomPicker: Bool
//
//    // Music
//    let tracks: [Track]
//    let freeTrackIDs: Set<String>
//    @Binding var selectedTrack: Track?
//    @Binding var musicVol: Double
//    @Binding var videoVol: Double
//    let onMusicChange: () -> Void
//
//    // Captions
//    @Binding var captionMode: MontageView.CaptionKind
//    let isCustomCaptionsOn: Bool
//    @Binding var customCaptionText: String
//    @Binding var showDates: Bool
//    let onCaptionsChange: () -> Void
//    // Captions (rich)
//    @Binding var captionColor: Color
//    @Binding var captionOpacity: Double
//    @Binding var captionFontSize: Double
//    @Binding var captionFont: MontageView.CaptionFontVariant
//    @Binding var captionPos: MontageView.CaptionPos3
//
//
//    // Orientation
//    @Binding var orientation: MontageView.Orientation
//    @Binding var contentMode: ContentMode
//    let onOrientationChange: () -> Void
//
//    // Export Quality
//    @Binding var exportQuality: MontageView.ExportQuality
//    let onQualityChange: () -> Void
//
//    // Watermark
//    @Binding var brandingOn: Bool
//    let onBrandingChange: () -> Void
//
//
//
//    var body: some View {
//        VStack(spacing: 10) {
//            switch selectedTab {
//            case .style:
//              StylesShelfVertical(T: T, selected: $selectedStyle) {
//                onCaptionsChange()
//              }
//
//            case .range:
//                RangeShelfVertical(
//                    T: T,
//                    rangeLabel: $rangeLabel,
//                    clipCount: clipCount,
//                    onChoosePreset: onChoosePreset,
//                    onChooseAll: onChooseAll,
//                    showCustomPicker: $showCustomPicker,
//                    onChooseMonths: { months in
//                        onChoosePreset(.month)   // parent still handles actual range update
//                    },
//                    onChooseYears: { years in
//                        onChoosePreset(.year)
//                    }
//                )
//
//
//            case .music:
//                MusicShelfVertical(
//                    T: T,
//                    tracks: tracks,
//                    freeTrackIDs: freeTrackIDs,
//                    selectedTrack: $selectedTrack,
//                    musicVol: $musicVol,
//                    videoVol: $videoVol,
//                    onChange: onMusicChange
//                )
//
//            case .captions:
//              CaptionsShelfVertical(
//                T: T,
//                captionMode: $captionMode,
//                isCustomCaptionsOn: isCustomCaptionsOn,
//                customCaptionText: $customCaptionText,
//                showDates: $showDates,
//                onChange: onCaptionsChange,
//
//                // ⬇️ NEW bindings you added to MontageView
//                captionColor: $captionColor,
//                captionOpacity: $captionOpacity,
//                captionFontSize: $captionFontSize,
//                captionFont: $captionFont,
//                captionPos: $captionPos
//              )
//
//
//            case .orientation:
//                OrientationShelfVertical(
//                    T: T,
//                    orientation: $orientation,
//                    contentMode: $contentMode,
//                    onChange: onOrientationChange
//                )
//
//             case .quality:
//                ExportQualityShelfVertical(
//                    T: T,
//                    exportQuality: $exportQuality,
//                    onChange: onQualityChange
//                )
//
//            case .watermark:
//                WatermarkShelfVertical(
//                    T: T,
//                    brandingOn: $brandingOn,
//                    onChange: onBrandingChange
//                )
//            }
//        }
//        .padding(.top, 2)
//    }
//}
