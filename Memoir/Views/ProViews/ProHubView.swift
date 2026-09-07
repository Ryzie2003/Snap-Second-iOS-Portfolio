import SwiftUI
import RevenueCat

private struct BrandLogo: View {
    let accent: Color
    @Environment(\.colorScheme) private var scheme

    private var layoutScale: LayoutScale {
        LayoutScale.forScreenHeight()
    }

    var body: some View {
        HStack(spacing: 8) {
            Image("SplashLogo")
                .resizable()
                .renderingMode(.original)
                .scaledToFit()
                .frame(height: layoutScale.proLogoHeight)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
        .shadow(color: scheme == .dark ? .white.opacity(0.06) : .black.opacity(0.10),
                radius: 8, y: 4)
    }
}

struct ProHubView: View {
    var onUpgrade: () -> Void = {}

    @Environment(\.colorScheme) private var scheme
    private var T: Theme { AppTheme.sunsetGlow.theme(for: scheme) }

    private var layoutScale: LayoutScale {
        LayoutScale.forScreenHeight()
    }

    @State private var proInfo: ProInfo = .init(isLoading: true)
    @State private var showWhatsNew = false
    @Environment(\.openURL) private var openURL
    private let entitlementID = "pro" // ← change to your actual RC entitlement id
    @EnvironmentObject private var entitlements: Entitlements


    // Inject these from parent if you have central routing; defaults provided:
    var onManageSubscription: () -> Void = {}
    var onOpenCloudBackup: () -> Void = {}
    var onOpenWatermark: () -> Void = {}
    var onOpenMusic: () -> Void = {}
    var onOpenJournals: () -> Void = {}
    var onOpenExport: () -> Void = {}
    var onContactSupport: () -> Void = {}

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {

                // Header
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        BrandLogo(accent: T.core.accent)          // ← new logo at left
                            .fixedSize()                           // prevents compression

                        Text("Snap Second Pro")
                            .font(.system(
                                size: layoutScale.proHeaderTitleSize,
                                weight: .heavy,
                                design: .rounded
                            ))
                            .foregroundStyle(.primary)

                        Spacer(minLength: 0)
                    }

                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: layoutScale.proBadgeTextSize, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(4)
                            .background(Capsule().fill(T.core.accent))

                        Text("Pro active • Thanks for supporting Snap Second")
                            .font(.system(
                                size: layoutScale.proHeaderSubtitleSize,
                                weight: .regular,
                                design: .rounded
                            ))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }


                    if entitlements.isFamilyShared {
                        HStack(spacing: 6) {
                            Image(systemName: "person.2.fill")
                                .font(.system(size: layoutScale.proBadgeTextSize, weight: .semibold))
                            Text("Shared via Family")
                                .font(.system(
                                    size: layoutScale.proBadgeTextSize,
                                    weight: .semibold,
                                    design: .rounded
                                ))
                        }
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 20)


                // Account/plan card
                ProPlanCard(T: T, info: proInfo)

                // Pro Benefits — raised card, non-clickable
                VStack(alignment: .leading, spacing: 12) {
                    Text("Pro Benefits")
                        .appSectionTitleStyle(T)

                    VStack(spacing: 0) {
                        HStack(spacing: 12) {
                            ZStack {
                                Circle()
                                    .fill(T.surfaceAlt)
                                    .frame(width: layoutScale.proCircleSize, height: layoutScale.proCircleSize)
                                Image(systemName: "sparkles")
                                    .font(.system(size: layoutScale.proCircleIconSize, weight: .semibold, design: .rounded))
                                    .foregroundStyle(T.core.accent)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Unlimited Journals")
                                    .font(.system(
                                        size: layoutScale.proRowTitleSize,
                                        weight: .semibold,
                                        design: .rounded
                                    ))
                                Text("Create as many as you like")
                                    .font(.system(
                                        size: layoutScale.proRowSubtitleSize,
                                        weight: .regular,
                                        design: .rounded
                                    ))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)


                        Divider()

                        // Music Library
                        HStack(spacing: 12) {
                            ZStack {
                                Circle().fill(T.surfaceAlt).frame(width: 36, height: 36)
                                Image(systemName: "music.note")
                                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                                    .foregroundStyle(T.core.accent)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Music Library")
                                    .font(.system(.body, design: .rounded).weight(.semibold))
                                Text("Custom & Royalty-free music for montages")
                                    .font(.system(.footnote, design: .rounded))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 12)

                        Divider()

                        // Cloud Backup
                        HStack(spacing: 12) {
                            ZStack {
                                Circle().fill(T.surfaceAlt).frame(width: 36, height: 36)
                                Image(systemName: "icloud.fill")
                                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                                    .foregroundStyle(T.core.accent)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Cloud Backup")
                                    .font(.system(.body, design: .rounded).weight(.semibold))
                                Text("Sync safely across devices")
                                    .font(.system(.footnote, design: .rounded))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 12)

                        Divider()

                        // Watermark Toggle
                        HStack(spacing: 12) {
                            ZStack {
                                Circle().fill(T.surfaceAlt).frame(width: 36, height: 36)
                                Image(systemName: "drop")
                                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                                    .foregroundStyle(T.core.accent)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Watermark Toggle")
                                    .font(.system(.body, design: .rounded).weight(.semibold))
                                Text("Enable or remove Snap Second branding")
                                    .font(.system(.footnote, design: .rounded))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 12)

                        Divider()

                        // HD Export
                        HStack(spacing: 12) {
                            ZStack {
                                Circle().fill(T.surfaceAlt).frame(width: 36, height: 36)
                                Image(systemName: "film.fill")
                                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                                    .foregroundStyle(T.core.accent)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text("HD Export")
                                    .font(.system(.body, design: .rounded).weight(.semibold))
                                Text("Export montages in high definition")
                                    .font(.system(.footnote, design: .rounded))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 12)
                    }
                    .background(
                      RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(T.core.surface)
                    )
                    .overlay(
                      RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(T.border, lineWidth: 1)
                    )
                    .shadow(color: scheme == .dark ? .white.opacity(0.06) : .black.opacity(0.08),
                            radius: 12, x: 0, y: 6)
                }




                // Account (white card, no AccountRow)
                VStack(alignment: .leading, spacing: 12) {
                    Text("Account")
                        .appSectionTitleStyle(T)

                    VStack(spacing: 0) {
                        // Manage subscription
                        Button {
                            openManageSubscription()
                        } label: {
                            HStack(spacing: 12) {
                                ZStack {
                                    Circle().fill(T.surfaceAlt).frame(width: 36, height: 36)
                                    Image(systemName: "person.badge.key.fill")
                                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                                        .foregroundStyle(T.core.accent)
                                }

                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Manage subscription")
                                        .font(.system(.body, design: .rounded).weight(.semibold))
                                        .foregroundStyle(.primary)

                                    Text(
                                        proInfo.isLifetime
                                        ? "Lifetime — no renewal"
                                        : (proInfo.willRenew
                                           ? (proInfo.renewalDate.map { "Renews \($0.formatted(date: .abbreviated, time: .omitted))" } ?? "Renews automatically")
                                           : "Does not auto-renew")
                                    )
                                    .font(.system(.footnote, design: .rounded))
                                    .foregroundStyle(.secondary)

                                    if entitlements.isFamilyShared {
                                        Text("Managed by the family organizer in Apple Subscriptions.")
                                            .font(.system(.footnote, design: .rounded))
                                            .foregroundStyle(.secondary)
                                    }
                                }

                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                        }
                        .buttonStyle(.plain)

                        Divider()

                        // Restore purchases
                        Button {
                            Task { await restorePurchases() }
                        } label: {
                            HStack(spacing: 12) {
                                ZStack {
                                    Circle().fill(T.surfaceAlt).frame(width: 36, height: 36)
                                    Image(systemName: "arrow.clockwise")
                                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                                        .foregroundStyle(T.core.accent)
                                }

                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Restore purchases")
                                        .font(.system(.body, design: .rounded).weight(.semibold))
                                        .foregroundStyle(.primary)
                                    Text("If you’ve switched devices")
                                        .font(.system(.footnote, design: .rounded))
                                        .foregroundStyle(.secondary)
                                }

                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                        }
                        .buttonStyle(.plain)
                    }
                    // white card like SettingsView sections
                    .background(
                      RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(T.core.surface)
                    )
                    .overlay(
                      RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(T.border, lineWidth: 1)
                    )
                    .shadow(color: scheme == .dark ? .white.opacity(0.06) : .black.opacity(0.08),
                            radius: 12, x: 0, y: 6)


                    Text("Subscriptions are managed by Apple. Restoring does not change your plan.")
                        .font(.system(
                            size: layoutScale.proRowSubtitleSize,
                            weight: .regular,
                            design: .rounded
                        ))
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)

            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .navigationBarTitleDisplayMode(.inline)
        .appScreenStyle(T)
        .task { await loadCustomerInfo() }
        .onReceive(Entitlements.shared.$isPro) { _ in
            Task { proInfo.isLoading = true; await loadCustomerInfo() }
        }
    }

    private func openManageSubscription() {
        // Match SettingsView: let RevenueCat decide where to send the user
        Task {
            try? await Purchases.shared.showManageSubscriptions()
        }
    }


    // RevenueCat helpers
    private func loadCustomerInfo() async {
        do {
            let info = try await Purchases.shared.customerInfo()
            let ent = info.entitlements.active.values.first

            // Heuristics for lifetime:
            // - RevenueCat lifetime (non-renewing) typically has no expirationDate and willRenew == false
            // - Some apps encode in product id (e.g. contains "lifetime")
            let pid = ent?.productIdentifier ?? ""
            let isLifetime = ((ent?.expirationDate == nil) && (ent?.willRenew == false))
                            || pid.localizedCaseInsensitiveContains("lifetime")

            proInfo = .init(
                productIdentifier: ent?.productIdentifier,
                willRenew: ent?.willRenew ?? true,
                renewalDate: ent?.expirationDate,
                managementURL: info.managementURL,
                isLifetime: isLifetime,
                isLoading: false
            )
        } catch {
            proInfo.isLoading = false
        }
    }


    private func restorePurchases() async {
        do {
            _ = try await Purchases.shared.restorePurchases()
            // Match SettingsView: make sure the shared entitlements state is up-to-date
            await Entitlements.shared.refreshEntitlements()
        } catch {
            // optional: log or surface an error if you want
            print("Restore purchases failed: \(error)")
        }
    }

}

private struct ProInfo {
    var productIdentifier: String? = nil
    var willRenew: Bool = true
    var renewalDate: Date? = nil
    var managementURL: URL? = nil
    var isLifetime: Bool = false
    var isLoading: Bool = true
}


private struct ProPlanCard: View {
    let T: Theme
    let info: ProInfo

    private var layoutScale: LayoutScale {
        LayoutScale.forScreenHeight()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {

            // Plan row — label left, value right (value can wrap)
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Label("Plan", systemImage: "tag.fill")
                    .font(.system(
                        size: layoutScale.proRowSubtitleSize,
                        weight: .regular,
                        design: .rounded
                    ))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 12)

                Text({
                    if info.isLoading { return "Fetching…" }
                    if info.isLifetime { return "Lifetime" }
                    if let pid = info.productIdentifier { return displayName(for: pid, isLifetime: info.isLifetime) }
                    return "Unavailable"
                }())
                .font(.system(
                        size: layoutScale.proRowTitleSize,
                        weight: .semibold,
                        design: .rounded
                    ))
                .multilineTextAlignment(.trailing)
                .lineLimit(2)                                  // allow wrap
                .minimumScaleFactor(0.9)                       // small downscale if truly tight
                .fixedSize(horizontal: false, vertical: true)  // prefer wrapping over compressing
                .layoutPriority(1)                             // keep value readable
            }
        }
        .appCard(T)
    }

    private func displayName(for productID: String, isLifetime: Bool) -> String {
        if isLifetime { return "Lifetime" }
        switch productID.lowercased() {
        case let s where s.contains("annual"): return "Annual"
        case let s where s.contains("year"):   return "Annual"
        case let s where s.contains("month"):  return "Monthly"
        default: return productID
        }
    }
}


private struct ProToolCard: View {
    let T: Theme
    let icon: String
    let title: String
    let subtitle: String

    private var layoutScale: LayoutScale {
        LayoutScale.forScreenHeight()
    }

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(T.surfaceAlt)
                    .frame(width: layoutScale.proCircleSize, height: layoutScale.proCircleSize)
                Image(systemName: icon)
                    .font(.system(size: layoutScale.proCircleIconSize, weight: .semibold, design: .rounded))
                    .foregroundStyle(T.core.accent)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(
                        size: layoutScale.proRowTitleSize,
                        weight: .semibold,
                        design: .rounded
                    ))
                    .foregroundStyle(.primary)
                Text(subtitle)
                        .font(.system(
                            size: layoutScale.proRowSubtitleSize,
                            weight: .regular,
                            design: .rounded
                        ))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(T.surfaceAlt)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(T.border, lineWidth: 1)
        )
    }
}


private struct AccountRow<Trailing: View>: View {
    let T: Theme
    let icon: String
    let title: String
    let subtitle: String?
    var action: () -> Void
    @ViewBuilder var trailing: Trailing

    private var layoutScale: LayoutScale {
        LayoutScale.forScreenHeight()
    }

    init(
        T: Theme,
        icon: String,
        title: String,
        subtitle: String? = nil,
        action: @escaping () -> Void,
        trailing: Trailing = EmptyView()
    ) {
        self.T = T
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.action = action
        self.trailing = trailing
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(T.surfaceAlt)
                        .frame(width: 36, height: 36)
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(T.core.accent)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(.body, design: .rounded).weight(.semibold))
                        .foregroundStyle(.primary)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(.footnote, design: .rounded))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }

                Spacer(minLength: 0)
                trailing
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
        .background(Color.clear)
    }
}

// MARK: - ProHub responsive tokens

private extension LayoutScale {
    /// "Snap Second Pro" header title
    var proHeaderTitleSize: CGFloat {
        switch self {
        case .small:  return 26
        case .medium: return 30
        case .large:  return 34
        }
    }

    /// Subtitle / “Pro active…” copy
    var proHeaderSubtitleSize: CGFloat {
        switch self {
        case .small:  return 12
        case .medium: return 14
        case .large:  return 15
        }
    }

    /// Small badge text (“Pro active…”, “Shared via Family”)
    var proBadgeTextSize: CGFloat {
        switch self {
        case .small:  return 11
        case .medium: return 12
        case .large:  return 13
        }
    }

    /// Logo height in the header
    var proLogoHeight: CGFloat {
        switch self {
        case .small:  return 32
        case .medium: return 36
        case .large:  return 40
        }
    }

    /// Circular icon background size in rows
    var proCircleSize: CGFloat {
        switch self {
        case .small:  return 32
        case .medium: return 36
        case .large:  return 40
        }
    }

    /// Glyph size inside those circles
    var proCircleIconSize: CGFloat {
        switch self {
        case .small:  return 14
        case .medium: return 16
        case .large:  return 18
        }
    }

    /// Main row title text (“Unlimited Journals”, “Manage subscription”, etc.)
    var proRowTitleSize: CGFloat {
        switch self {
        case .small:  return 14
        case .medium: return 16
        case .large:  return 17
        }
    }

    /// Row subtitle text (“Create as many as you like”, etc.)
    var proRowSubtitleSize: CGFloat {
        switch self {
        case .small:  return 12
        case .medium: return 13
        case .large:  return 14
        }
    }
}
