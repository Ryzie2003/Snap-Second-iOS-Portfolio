import SwiftUI
import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins
import PhosphorSwift

struct DayCellTheme {
    let surface: Color
    let tileBG: Color
    let border: Color
    let dateBadgeBG: Color
    let dateBadgeFG: Color
    let stackBG: Color
    let stackFG: Color
    let todayRing: Color
}

enum DayEmptyBadge {
    case video, livePhoto, photo

    var symbolName: String {
        switch self {
        case .video:     return "video.fill"
        case .livePhoto: return "livephoto"
        case .photo:     return "photo"
        }
    }
}



struct DayCell: View {
    let dayNumber : Int
    let thumbnail : UIImage?
    let asyncThumbData: Data?
    let thumbKey: String?
    var isToday   : Bool = false
    var clipCount : Int  = 0
    var theme     : DayCellTheme
    var emptyBadge: DayEmptyBadge? = nil
    var weekdayAbbrev: String? = nil
    var rotationDegrees: Double = 0  // ← New parameter for rotation

    private let badgeSize: CGFloat = 24
    private let cellCorner: CGFloat = 10
    private let px: CGFloat = 1 / UIScreen.main.scale

    @State private var avgTint: Color? = nil
    @Environment(\.colorScheme) private var scheme


    var body: some View {
        GeometryReader { geo in
            let side = geo.size.width

            let elev: CGFloat = (clipCount > 0 ? 3 : 2) + (isToday ? 1 : 0)

            ZStack {
                // Background / thumbnail
                Group {
                    if let data = asyncThumbData {
                        AsyncThumbImage(data: data, key: thumbKey ?? "day-\(dayNumber)")
                            .scaledToFill()
                            .rotationEffect(.degrees(rotationDegrees))
                    } else if let img = thumbnail {
                        Image(uiImage: img).resizable().scaledToFill()
                            .rotationEffect(.degrees(rotationDegrees))
                    } else {
                        theme.tileBG
                    }
                }
                .frame(width: side, height: side)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: cellCorner))

                if let tint = avgTint {
                    RoundedRectangle(cornerRadius: cellCorner)
                        .fill(tint.opacity(0.06))
                }

                // Date/Weekday badge (top-left)
                Group {
                    if let wd = weekdayAbbrev {
                        // White in dark mode. In light mode: white over photos, otherwise theme-provided FG.
                        // Badge foreground color rules:
                        // - Dark mode: white over images; otherwise use theme's FG
                        // - Light mode: white over images; otherwise darkened theme FG for empty tiles
                        let fg: Color = {
                            if scheme == .dark {
                                return (asyncThumbData != nil && clipCount > 0) ? .white : theme.dateBadgeBG
                            } else {
                                if clipCount == 0 { return theme.dateBadgeBG.darken(0.35) }
                                return (asyncThumbData != nil) ? .white : theme.dateBadgeBG.darken(0.35)
                            }
                        }()


                        // Larger, left-aligned two-line badge: "MON" (smaller) above big date number
                        VStack(alignment: .leading, spacing: 0) {
                            Text(wd.uppercased())
                                .font(.system(size: 14, weight: .semibold))   // ↑ larger weekday
                                .minimumScaleFactor(0.85)
                                .lineLimit(1)

                            Text("\(dayNumber)")
                                .font(.system(size: 18, weight: .heavy))      // ↑ noticeably larger number
                                .minimumScaleFactor(0.85)
                                .lineLimit(1)
                        }
                        .foregroundStyle(fg)
                        .shadow(color: asyncThumbData != nil ? .black.opacity(0.35) : .clear, radius: 2, y: 1)
                        // Park it cleanly in the top-left without hard-coding the pill width
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(10)
                    } else {
                        // (keep your original circular chip fallback unchanged)
                        Text("\(dayNumber)")
                            .font(.caption.bold())
                            .foregroundStyle(theme.dateBadgeFG)
                            .frame(width: badgeSize, height: badgeSize)
                            .background(Circle().fill(theme.dateBadgeBG))
                            .shadow(color: theme.border.opacity(0.6), radius: 2, y: 1)
                            .position(x: 6 + badgeSize/2, y: 6 + badgeSize/2)
                    }

                }


                if clipCount > 1 {
                    HStack(spacing: 4) {
                        Image(systemName: "square.stack.3d.up.fill")
                            .font(.caption.weight(.semibold))
                        Text("\(clipCount)")
                            .font(.caption2.weight(.bold))
                    }
                    .foregroundStyle(theme.stackFG)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(theme.stackBG, in: Capsule())
                    .shadow(radius: 1, y: 1)
                    .position(x: side - 24, y: side - 6 - 12)
                }



                if thumbnail == nil, let kind = emptyBadge {
                    HStack(spacing: 6) {
                        Image(systemName: kind.symbolName)
                            .font(.caption.weight(.bold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .shadow(color: .black.opacity(0.5), radius: 3, y: 2)
                    .position(x: 20, y: side - 22)
                }

                if isToday {
                    let hl = 1 / UIScreen.main.scale
                    RoundedRectangle(cornerRadius: cellCorner)
                        .inset(by: hl) // sit just inside the hairline
                        .stroke(theme.todayRing, lineWidth: 2)
                        .shadow(color: theme.todayRing.opacity(0.35), radius: 3, y: 1)
                }
                // ── Per-cell edge definition (works in both modes; tuned for dark)
                RoundedRectangle(cornerRadius: cellCorner)
                    .inset(by: px) // sit just inside the grid hairline
                    .stroke(
                        (scheme == .dark ? Color.white.opacity(0.10) : theme.border.opacity(0.90)),
                        lineWidth: px
                    )

                // Subtle inner highlight so the edge “reads” over thumbnails as well
                RoundedRectangle(cornerRadius: cellCorner)
                    .inset(by: px * 2)
                    .stroke(
                        (scheme == .dark ? Color.white.opacity(0.06) : Color.white.opacity(0.10)),
                        lineWidth: px
                    )

            }
            .background(
                RoundedRectangle(cornerRadius: cellCorner)
                    .fill(theme.surface)
                    .shadow(color: .black.opacity(0.10), radius: elev * 1.6, x: 0, y: elev)
                    .shadow(color: .black.opacity(0.05), radius: elev,       x: 0, y: elev * 0.8)
            )
            .compositingGroup()
            .frame(width: side, height: side)
        }
        .aspectRatio(1, contentMode: .fit)
        .task(id: thumbKey ?? "\(asyncThumbData?.count ?? 0)") {
           guard let data = asyncThumbData, let key = thumbKey else { avgTint = nil; return }
           let ui = await averageUIColor(for: data, key: key)
           await MainActor.run { avgTint = ui.map(Color.init) }
       }
    }
}

private final class AvgColorCache {
    static let shared = AvgColorCache()
    private let cache = NSCache<NSString, UIColor>()
    func get(_ key: String) -> UIColor? { cache.object(forKey: key as NSString) }
    func set(_ key: String, _ color: UIColor) { cache.setObject(color, forKey: key as NSString) }
}

/// Compute an average color from image data off-main and cache it.
private func averageUIColor(for data: Data, key: String) async -> UIColor? {
    if let c = AvgColorCache.shared.get(key) { return c }
    guard let ci = CIImage(data: data) else { return nil }
    let context = CIContext(options: [.priorityRequestLow: true])
    let filter = CIFilter.areaAverage()
    filter.inputImage = ci
    filter.extent = ci.extent
    guard let out = filter.outputImage else { return nil }

    var rgba = [UInt8](repeating: 0, count: 4)
    context.render(out,
                   toBitmap: &rgba, rowBytes: 4,
                   bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                   format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
    let uic = UIColor(red: CGFloat(rgba[0])/255, green: CGFloat(rgba[1])/255, blue: CGFloat(rgba[2])/255, alpha: 1)
    AvgColorCache.shared.set(key, uic)
    return uic
}
