import SwiftUI
import UserNotifications
import PhotosUI
import MessageUI
import UniformTypeIdentifiers
import FirebaseAuth
import FirebaseFirestore
import FirebaseStorage
import AVFoundation
import Combine
import RevenueCat
import StoreKit
import PhosphorSwift


// MARK: - Cards

private struct ProfileHeaderCard: View {
    let isSignedIn: Bool
    let email: String?
    var onSignIn: () -> Void
    var onSignOut: () -> Void

    private var layoutScale: LayoutScale {
            LayoutScale.forScreenHeight()
        }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Ph.userCircle.fill
                .frame(width: 44, height: 44)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text(isSignedIn ? "Signed in with Apple" : "Not signed in")
                    .font(.system(
                        size: layoutScale.settingsRowBodySize,
                        weight: .semibold,
                        design: .rounded
                    ))

                Text(isSignedIn ? (email ?? "—") : "Required for Cloud Backup & syncing purchases")
                    .font(.system(
                        size: layoutScale.settingsFootnoteSize,
                        weight: .regular,
                        design: .rounded
                    ))
                    .foregroundStyle(.secondary)

                HStack {
                    if !isSignedIn {
                        Button {
                            onSignIn()
                        } label: {
                            Label("Sign in with Apple", systemImage: "apple.logo")
                        }
                        .font(.system(
                                    size: layoutScale.settingsRowBodySize,
                                    weight: .semibold,
                                    design: .rounded
                                ))
                    }
                    // If signed in → no sign-out button here anymore
                }
            }

        }
        .padding(.vertical, 2)
    }
}

private struct FooterVersionRow: View {
    var body: some View {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "-"
        Text("Snap Second v\(v) (\(b))")
            .font(.system(
                size: LayoutScale.forScreenHeight().settingsFootnoteSize,
                weight: .regular,
                design: .rounded
            ))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 12)
            .listRowBackground(Color.clear)   // transparent
    }
}


struct SettingsView: View {
    @Environment(\.colorScheme) private var scheme
    private var T: Theme { AppTheme.sunsetGlow.theme(for: scheme) }

    private var layoutScale: LayoutScale {
        LayoutScale.forScreenHeight()
    }

    @EnvironmentObject private var clipStore: ClipStore

    @EnvironmentObject private var authManager: AuthManager

    // Persisted notification prefs
    @AppStorage("notif.mode")   private var notifModeRaw: String = NotificationMode.off.rawValue
    @AppStorage("notif.hour")   private var notifHour: Int = 17
    @AppStorage("notif.minute") private var notifMinute: Int = 0

    // One-time sheet tracking
    @AppStorage("shownTimeSensitiveTip") private var shownTimeSensitiveTip: Bool = false
    @State private var showingTimeSensitiveSheet = false

    // Local, snappy selection for the segmented control
    @State private var selection: NotificationMode =
        NotificationMode(rawValue: UserDefaults.standard.string(forKey: "notif.mode") ?? "") ?? .off

    @State private var applying = false
    @State private var applyTask: Task<Void, Never>? = nil
    @State private var showingAuthTip = false

    // Cloud Backup UI state
    @AppStorage("cloudBackup.enabled") private var cloudBackupOn: Bool = false

    @AppStorage("appearance.mode") private var appearanceRaw: String = AppearanceMode.system.rawValue

    // Clip defaults
    @AppStorage(ClipDefaults.durationKey) private var defaultClipDuration: Double = ClipDefaults.defaultDuration
    @AppStorage(ClipDefaults.orientationKey) private var defaultClipOrientationRaw: String = ClipDefaults.defaultOrientationRaw

    private var appearanceMode: AppearanceMode {
        get { AppearanceMode(rawValue: appearanceRaw) ?? .system }
        set { appearanceRaw = newValue.rawValue }
    }

    private var defaultClipOrientation: PreviewFill {
        PreviewFill(rawValue: defaultClipOrientationRaw) ?? .portrait
    }

    @State private var backupBusy = false
    @State private var backupStatusText: String = "Off"
    @State private var showBackupAuthAlert = false
    @State private var backupTotal: Int = 0
    @State private var backupDone: Int = 0
    @State private var backupState: BackupState = .idle
    @State private var progressCancellable: AnyCancellable?

    @State private var showMore: Bool = false

    @State private var showDeleteConfirm = false
    @State private var deletingAccount = false
    @State private var deleteError: String?


    // Pro
    @EnvironmentObject private var entitlements: Entitlements
    @Environment(\.openURL) private var openURL
    @State private var restoringPurchases = false
    @State private var restoreAlert: String? = nil

    // MARK: - Stats

    /// All clips across all journals
    // Use ClipStore's in-memory snapshot; no Core Data fetch here.
    private var allClips: [Clip] {
        clipStore.clips
    }


    /// 1) Total moments captured (all journals)
    private var totalMoments: Int { allClips.count }

    /// 2) Longest day-by-day streak (across all journals)
    private var longestDailyStreak: Int {
        // Collapse to unique calendar days
        let cal = Calendar.current
        let days = Set(allClips.compactMap { $0.date.map { cal.startOfDay(for: $0) } })
            .sorted()
        guard !days.isEmpty else { return 0 }

        var longest = 1, current = 1
        for i in 1..<days.count {
            if cal.isDate(days[i], inSameDayAs: cal.date(byAdding: .day, value: 1, to: days[i-1])!) {
                current += 1
                longest = max(longest, current)
            } else {
                current = 1
            }
        }
        return longest
    }

    private var longestMontageSeconds: Int {
        // Sum durations per journal using the in-memory clips snapshot.
        var totalsByProject: [UUID: Double] = [:]

        for clip in allClips {
            guard let pid = clip.projectID else { continue }
            totalsByProject[pid, default: 0.0] += max(0.0, clip.duration)
        }

        let maxSec = totalsByProject.values.max() ?? 0.0
        // If you want to include a 2s end card or similar, adjust here.
        return Int(maxSec.rounded())
    }


    private func openWriteReviewPage() {
        // Replace with your real App Store numeric ID (e.g., 1234567890)
        if let url = URL(string: "https://apps.apple.com/us/app/snap-second/id6749602215?action=write-review") {
            openURL(url)
        }
    }



    // MARK: - Formatting

    /// 42  -> "42 s"
    /// 75  -> "1 m 15 s"
    private func formatDuration(_ seconds: Int) -> String {
        guard seconds >= 0 else { return "0 s" }
        if seconds < 60 { return "\(seconds) s" }
        let m = seconds / 60
        let s = seconds % 60
        return "\(m) m \(s) s"
    }

    private func formatClipDuration(_ seconds: Double) -> String {
        String(format: "%.1f s", seconds)
    }

    private let clipDurationOptions: [Double] =
        Array(stride(from: 0.5, through: 5.0, by: 0.5))

    // Notification state bridging (@AppStorage ←→ picker @State)
    @State private var notifSelection: NotificationMode =
        NotificationMode(rawValue: UserDefaults.standard.string(forKey: "notif.mode") ?? "") ?? .off
    @State private var notifApplying = false

    private func debounceReschedule() {
        // Avoid prompting while the user is just tweaking the time.
        Task { await rescheduleNotifications(mode: notifSelection, promptIfDenied: false) }
    }

    private func rescheduleNotifications(mode: NotificationMode, promptIfDenied: Bool) async {
        await MainActor.run { notifApplying = true }
        try? await Task.sleep(nanoseconds: 200_000_000)

        if mode == .off {
            await NotificationManager.apply(mode: mode, hour: notifHour, minute: notifMinute)
            await MainActor.run { notifApplying = false }
            return
        }

        if !promptIfDenied {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                NotificationManager.registerCategories()
                await NotificationManager.apply(mode: mode, hour: notifHour, minute: notifMinute)
            default:
                break
            }
            await MainActor.run { notifApplying = false }
            return
        }

        let ok = await NotificationManager.requestAuthorizationIfNeeded()
        if ok {
            NotificationManager.registerCategories()
            await NotificationManager.apply(mode: mode, hour: notifHour, minute: notifMinute)
        } else {
            await MainActor.run { showingAuthTip = true }
        }
        await MainActor.run { notifApplying = false }
    }

    var body: some View {
            List {
                Text("Settings")
                    .font(.system(
                        size: layoutScale.settingsTitleSize,
                        weight: .heavy,
                        design: .rounded
                    ))
                    .foregroundStyle(T.core.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .listRowBackground(Color.clear)


                // 0) Profile header card
                Section { ProfileHeaderCard(isSignedIn: isSignedIn,
                    email: Auth.auth().currentUser?.email,
                    onSignIn: {
                        Task {
                            let window = UIApplication.shared.connectedScenes
                                .compactMap { $0 as? UIWindowScene }
                                .first?.keyWindow
                            try? await authManager.signInWithApple(
                                linkIfAnonymous: true,
                                presentingWindow: window
                            )
                        }
                    },
                    onSignOut: { authManager.signOut() })
                }
                .listRowBackground(Color.clear)
                .textCase(nil)

                // 1) Subscription — promo banner (matches screenshot)
                VStack(alignment: .leading, spacing: 12) {
                    // Keep your nice section header
                    Text("Subscription")
                        .appSectionTitleStyle(T, fontSize: layoutScale.settingsSectionHeaderSize)

                    SubscriptionPromoCard(
                        T: T,
                        isPro: entitlements.isPro,
                        onPrimaryTap: {
                            if entitlements.isPro {
                                Task { try? await Purchases.shared.showManageSubscriptions() }
                            } else {
                                PaywallCoordinator.shared.present()
                            }
                        },
                        onRestore: {
                            Task {
                                restoringPurchases = true
                                _ = try? await Purchases.shared.restorePurchases()
                                await Entitlements.shared.refreshEntitlements()
                                restoringPurchases = false
                                restoreAlert = "Purchases restored."
                            }
                        }
                    )
                    // Show family-sharing status subtly beneath the banner
                    if entitlements.isPro, entitlements.isFamilyShared {
                        HStack(spacing: 6) {
                            Ph.usersThree.fill
                                .frame(width: 30, height: 30)
                            Text("Shared via Family")
                                .font(.system(
                                    size: layoutScale.settingsFootnoteSize,
                                    weight: .semibold,
                                    design: .rounded
                                ))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 4)
                    }
                }
                .listRowBackground(Color.clear)
                .textCase(nil)

                // Streaks — raised card (matches other settings sections)
                VStack(alignment: .leading, spacing: 12) {
                    Text("Streaks")
                        .appSectionTitleStyle(T, fontSize: layoutScale.settingsSectionHeaderSize)


                    VStack(spacing: 0) {
                        // Row 1 — Longest daily streak
                        HStack(spacing: 12) {
                            Ph.flame.fill
                                .frame(
                                    width: layoutScale.settingsIconSize,
                                    height: layoutScale.settingsIconSize
                                )
                                .foregroundStyle(T.core.accent)

                            Text("Longest daily streak")
                                .font(.system(
                                    size: layoutScale.settingsRowBodySize,
                                    weight: .semibold,
                                    design: .rounded
                                ))
                                .foregroundStyle(.primary)

                            Spacer(minLength: 0)

                            Text("\(longestDailyStreak) days")
                                .font(.system(
                                            size: layoutScale.settingsRowBodySize,
                                            weight: .semibold,
                                            design: .rounded
                                        ))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .padding(.horizontal, 16 * layoutScale.spacingScale)
                        .padding(.vertical, layoutScale.settingsRowVerticalPadding)

                        Divider()

                        // Row 2 — Longest montage duration
                        HStack(spacing: 12) {
                            ZStack {

                                Ph.filmStrip.fill
                                    .frame(
                                        width: layoutScale.settingsIconSize,
                                        height: layoutScale.settingsIconSize
                                    )
                                    .foregroundStyle(T.core.accent)
                            }

                            Text("Longest Snap Second montage")
                                .font(.system(
                                    size: layoutScale.settingsRowBodySize,
                                    weight: .semibold,
                                    design: .rounded
                                ))
                                .foregroundStyle(.primary)

                            Spacer(minLength: 0)

                            Text(formatDuration(longestMontageSeconds))
                                .font(.system(
                                    size: layoutScale.settingsRowBodySize,
                                    weight: .semibold,
                                    design: .rounded
                                ))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()

                        }
                        .padding(.horizontal, 16 * layoutScale.spacingScale)
                        .padding(.vertical, layoutScale.settingsRowVerticalPadding)
                    }

                    .overlay(
                      RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(T.border, lineWidth: 1)
                    )
                    .shadow(color: scheme == .dark ? .white.opacity(0.06) : .black.opacity(0.08),
                            radius: 12, x: 0, y: 6)
                }
                .listRowBackground(Color.clear)

                // Cloud Backup — raised card
                VStack(alignment: .leading, spacing: 12) {
                    Text("Cloud Backup")
                        .appSectionTitleStyle(T, fontSize: layoutScale.settingsSectionHeaderSize)


                    VStack(spacing: 0) {
                        // === Keep your existing toggle row ===
                        HStack {
                            ZStack {

                                Image(systemName: "icloud.fill").foregroundStyle(T.core.accent)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text("Cloud Backup")
                                        .font(.system(
                                            size: layoutScale.settingsRowBodySize,
                                            weight: .semibold,
                                            design: .rounded
                                        ))
                                        .foregroundStyle(.primary)

                                    ProMark()
                                }
                                Text(backupStatusText)
                                    .font(.system(
                                        size: layoutScale.settingsFootnoteSize,
                                        weight: .regular,
                                        design: .rounded
                                    ))
                                    .foregroundStyle(.secondary)

                            }
                            Spacer()
                            Toggle("", isOn: $cloudBackupOn)
                                .labelsHidden()
                                .tint(T.core.accent)
                        }
                        .padding(.horizontal, 16 * layoutScale.spacingScale)
                        .padding(.vertical, layoutScale.settingsRowVerticalPadding)
                        .disabled(backupBusy)
                        .onChange(of: cloudBackupOn) { newValue in
                            Task { await handleCloudBackupToggle(newValue) }
                        }
                        .alert("Sign in required", isPresented: $showBackupAuthAlert) {
                            Button("Sign in") { Task { await triggerSignInFlow() } }
                            Button("Cancel", role: .cancel) { }
                        } message: {
                            Text("Sign in with Apple is required to use Cloud Backup.")
                        }

                        Divider()

                        NavigationLink {
                            BackupsListView()
                        } label: {
                            HStack(spacing: 8) {
                                Label {
                                    Text("Restore from Backup…")
                                        .font(.system(
                                            size: layoutScale.settingsRowBodySize,   // ← Responsive size
                                            weight: .semibold,
                                            design: .rounded
                                        ))
                                } icon: {
                                    Image(systemName: "arrow.down.circle")
                                        .font(.system(size: layoutScale.settingsIconSize))
                                }

                                ProMark()

                                if backupBusy {
                                    ProgressView()
                                        .scaleEffect(layoutScale == .small ? 0.7 : 1.0)
                                }
                            }
                        }
                        .disabled(backupBusy || !(entitlements.isPro && isSignedIn))
                        .padding(.horizontal, 16)
                        .padding(.vertical, layoutScale.settingsRowVerticalPadding)

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
                .listRowBackground(Color.clear)

                // “See more” expander
                Button {
                    withAnimation(.easeInOut) { showMore.toggle() }
                } label: {
                    HStack {
                        Text(showMore ? "See less" : "Advanced Settings")
                            .font(.system(
                                size: layoutScale.settingsFootnoteSize,
                                weight: .semibold,
                                design: .rounded
                            ))
                            .foregroundStyle(T.core.accent)
                        Spacer()
                        Group {
                            if showMore {
                                Ph.caretUp.bold
                                    .frame(width: 20, height: 20)
                            } else {
                                Ph.caretDown.bold
                                    .frame(width: 20, height: 20)
                            }
                        }
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(T.core.accent)

                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)   // ← NEW
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.clear)


                if showMore {
                    VStack(alignment: .leading, spacing: 12) {
                        // Keep your existing title
                        Text("Preferences")
                            .appSectionTitleStyle(T, fontSize: layoutScale.settingsSectionHeaderSize)


                        VStack(spacing: 0) {
                            // Wrap all existing preference rows in the card
                            VStack(spacing: 0) {
                                // Row with summary
                                HStack {
                                    ZStack {

                                        Ph.bellSimpleRinging.fill
                                            .frame(
                                                width: layoutScale.settingsIconSize,
                                                height: layoutScale.settingsIconSize
                                            )
                                            .foregroundStyle(T.core.accent)
                                    }
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Notifications & Reminders")
                                            .font(.system(
                                                size: layoutScale.settingsRowBodySize,
                                                weight: .semibold,
                                                design: .rounded
                                            ))
                                        Text(notifSelection == .off
                                             ? "Off"
                                             : "Daily \(String(format: "%02d:%02d", notifHour, notifMinute))")
                                            .font(.system(
                                                size: layoutScale.settingsFootnoteSize,
                                                weight: .regular,
                                                design: .rounded
                                            ))
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 16 * layoutScale.spacingScale)
                                .padding(.vertical, layoutScale.settingsRowVerticalPadding)

                                Divider()

                                // Segmented control
                                Picker("Notification type", selection: $notifSelection) {
                                    ForEach(NotificationMode.allCases) { m in
                                        Text(m.title).tag(m)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .disabled(notifApplying)
                                .onChange(of: notifSelection) { newValue in
                                    DispatchQueue.main.async { notifModeRaw = newValue.rawValue }
                                    Task {
                                        await rescheduleNotifications(
                                            mode: newValue,
                                            promptIfDenied: newValue != .off
                                        )
                                    }
                                }
                                .padding(.horizontal, 16 * layoutScale.spacingScale)
                                .padding(.vertical, layoutScale.settingsRowVerticalPadding)

                                if notifSelection != .off {
                                    Divider()

                                    VStack(spacing: 8) {

                                        // Smaller responsive label (centered)
                                        Text("Reminder time")
                                            .font(.system(
                                                size: layoutScale.settingsFootnoteSize,
                                                weight: .semibold,
                                                design: .rounded
                                            ))
                                            .foregroundStyle(.primary)
                                            .frame(maxWidth: .infinity, alignment: .center)

                                        // Centered, compact, responsive DatePicker
                                        DatePicker(
                                            "",
                                            selection: Binding(
                                                get: {
                                                    Calendar.current.date(
                                                        from: DateComponents(hour: notifHour, minute: notifMinute)
                                                    ) ?? Date()
                                                },
                                                set: { newDate in
                                                    let c = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                                                    notifHour = c.hour ?? 17
                                                    notifMinute = c.minute ?? 0
                                                    debounceReschedule()
                                                }
                                            ),
                                            displayedComponents: .hourAndMinute
                                        )
                                        .labelsHidden()
                                        .datePickerStyle(.compact)
                                        .scaleEffect(
                                            layoutScale == .small ? 0.9 : 1.0,
                                            anchor: .center   // important: scales while staying centered
                                        )
                                        .frame(maxWidth: .infinity, alignment: .center)
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, layoutScale.settingsRowVerticalPadding)
                                }

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
                    }
                    .listRowBackground(Color.clear)

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Clip Defaults")
                            .appSectionTitleStyle(T, fontSize: layoutScale.settingsSectionHeaderSize)

                        VStack(spacing: 0) {
                            HStack(spacing: 12) {
                                Ph.timer.regular
                                    .frame(
                                        width: layoutScale.settingsIconSize,
                                        height: layoutScale.settingsIconSize
                                    )
                                    .foregroundStyle(T.core.accent)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Default Duration")
                                        .font(.system(
                                            size: layoutScale.settingsRowBodySize,
                                            weight: .semibold,
                                            design: .rounded
                                        ))
                                        .foregroundStyle(.primary)
                                    Text("Used for new clips and first edits")
                                        .font(.system(
                                            size: layoutScale.settingsFootnoteSize,
                                            weight: .regular,
                                            design: .rounded
                                        ))
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                Picker("", selection: $defaultClipDuration) {
                                    ForEach(clipDurationOptions, id: \.self) { value in
                                        Text(formatClipDuration(value)).tag(value)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                                .tint(T.core.accent)
                            }
                            .padding(.horizontal, 16 * layoutScale.spacingScale)
                            .padding(.vertical, layoutScale.settingsRowVerticalPadding)

                            Divider()

                            HStack(spacing: 12) {
                                Ph.crop.regular
                                    .frame(
                                        width: layoutScale.settingsIconSize,
                                        height: layoutScale.settingsIconSize
                                    )
                                    .foregroundStyle(T.core.accent)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Default Orientation")
                                        .font(.system(
                                            size: layoutScale.settingsRowBodySize,
                                            weight: .semibold,
                                            design: .rounded
                                        ))
                                        .foregroundStyle(.primary)
                                    Text(defaultClipOrientation.label)
                                        .font(.system(
                                            size: layoutScale.settingsFootnoteSize,
                                            weight: .regular,
                                            design: .rounded
                                        ))
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                Picker("", selection: $defaultClipOrientationRaw) {
                                    ForEach(PreviewFill.allCases) { fill in
                                        Text(fill.label).tag(fill.rawValue)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                                .tint(T.core.accent)
                            }
                            .padding(.horizontal, 16 * layoutScale.spacingScale)
                            .padding(.vertical, layoutScale.settingsRowVerticalPadding)
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
                    .listRowBackground(Color.clear)

                    // 4) Support — raised card, no AccountRow
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Support")
                            .appSectionTitleStyle(T, fontSize: layoutScale.settingsSectionHeaderSize)


                        VStack(spacing: 0) {

                            if isSignedIn {


                                Button(role: .destructive) {
                                    authManager.signOut()
                                } label: {
                                    HStack(spacing: 12) {
                                        Ph.signOut.fill
                                            .frame(
                                                width: layoutScale.settingsIconSize,
                                                height: layoutScale.settingsIconSize
                                            )
                                            .foregroundStyle(.red)
                                        Text("Sign Out")
                                            .font(.system(
                                                size: layoutScale.settingsRowBodySize,
                                                weight: .semibold,
                                                design: .rounded
                                            ))
                                            .foregroundStyle(.red)
                                        Spacer()
                                        Ph.caretRight.bold
                                            .frame(width: 20, height: 20)
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 14)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)

                                Divider().overlay(T.border)

                            }


                            // Terms of Service
                            Button {
                                openURL(Links.terms)
                            } label: {
                                HStack(spacing: 12) {
                                    Ph.fileText.fill
                                        .frame(
                                                    width: layoutScale.settingsIconSize,
                                                    height: layoutScale.settingsIconSize
                                                )
                                        .foregroundStyle(T.core.accent)
                                    Text("Terms of Service")
                                        .font(.system(
                                            size: layoutScale.settingsRowBodySize,
                                            weight: .semibold,
                                            design: .rounded
                                        ))
                                        .foregroundStyle(.primary)

                                    Spacer()
                                    Ph.caretRight.bold
                                        .frame(width: 20, height: 20)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 16 * layoutScale.spacingScale)
                                .padding(.vertical, layoutScale.settingsRowVerticalPadding)
                                .frame(maxWidth: .infinity, alignment: .leading)   // ← NEW
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            Divider().overlay(T.border)

                            // Privacy Policy
                            Button {
                                openURL(Links.privacy)
                            } label: {
                                HStack(spacing: 12) {
                                    Ph.shieldCheck.fill
                                        .frame(
                                                    width: layoutScale.settingsIconSize,
                                                    height: layoutScale.settingsIconSize
                                                )
                                        .foregroundStyle(T.core.accent)
                                    Text("Privacy Policy")
                                        .font(.system(
                                            size: layoutScale.settingsRowBodySize,
                                            weight: .semibold,
                                            design: .rounded
                                        ))
                                        .foregroundStyle(.primary)

                                    Spacer()
                                    Ph.caretRight.bold
                                        .frame(width: 20, height: 20)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 16 * layoutScale.spacingScale)
                                .padding(.vertical, layoutScale.settingsRowVerticalPadding)
                                .frame(maxWidth: .infinity, alignment: .leading)   // ← NEW
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            Divider().overlay(T.border)

                            // Rate & Review
                            Button {
                                openWriteReviewPage()
                            } label: {
                                HStack(spacing: 12) {
                                    Ph.star.fill
                                        .frame(
                                                    width: layoutScale.settingsIconSize,
                                                    height: layoutScale.settingsIconSize
                                                )
                                        .foregroundStyle(T.core.accent)
                                    Text("Rate & Review Snap Second")
                                        .font(.system(
                                            size: layoutScale.settingsRowBodySize,
                                            weight: .semibold,
                                            design: .rounded
                                        ))
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    Ph.caretRight.bold
                                        .frame(width: 20, height: 20)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 16 * layoutScale.spacingScale)
                                .padding(.vertical, layoutScale.settingsRowVerticalPadding)
                                .frame(maxWidth: .infinity, alignment: .leading)   // ← NEW
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            Divider().overlay(T.border)

                            // Contact Support (mailto)
                            Button {
                                openURL(Links.support)
                            } label: {
                                HStack(spacing: 12) {
                                    Ph.paperPlaneTilt.fill
                                        .frame(
                                                    width: layoutScale.settingsIconSize,
                                                    height: layoutScale.settingsIconSize
                                                )
                                        .foregroundStyle(T.core.accent)
                                    Text("Contact Support")
                                        .font(.system(
                                            size: layoutScale.settingsRowBodySize,
                                            weight: .semibold,
                                            design: .rounded
                                        ))
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    Ph.caretRight.bold
                                        .frame(width: 20, height: 20)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 16 * layoutScale.spacingScale)
                                .padding(.vertical, layoutScale.settingsRowVerticalPadding)
                                .frame(maxWidth: .infinity, alignment: .leading)   // ← NEW
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            Divider().overlay(T.border)

                            Button(role: .destructive) {
                                        showDeleteConfirm = true
                                    } label: {
                                        HStack(spacing: 12) {
                                            Ph.trash.fill
                                                .frame(
                                                            width: layoutScale.settingsIconSize,
                                                            height: layoutScale.settingsIconSize
                                                        )
                                                .foregroundStyle(.red)
                                            Text("Delete My Account & Cloud Data")
                                                .font(.system(
                                                    size: layoutScale.settingsRowBodySize,
                                                    weight: .semibold,
                                                    design: .rounded
                                                ))
                                                .foregroundStyle(.red)
                                            Spacer()
                                            Ph.caretRight.bold
                                                .frame(width: 20, height: 20)
                                                .foregroundStyle(.secondary)
                                        }
                                        .padding(.horizontal, 16 * layoutScale.spacingScale)
                                        .padding(.vertical, layoutScale.settingsRowVerticalPadding)
                                        .frame(maxWidth: .infinity, alignment: .leading)   // ← NEW
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(deletingAccount)
                                    .accessibilityHint("Deletes your Snap Second account from the cloud. Local files remain on device.")
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

                        if deletingAccount {
                                HStack(spacing: 8) {
                                    ProgressView()
                                    Text("Deleting… This can take a minute for large backups.")
                                        .font(.system(
                                            size: layoutScale.settingsFootnoteSize,
                                            weight: .regular,
                                            design: .rounded
                                        ))
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 4)
                            }
                            if let err = deleteError {
                                Text(err)
                                    .foregroundStyle(.red)
                                    .font(.system(
                                        size: layoutScale.settingsFootnoteSize,
                                        weight: .regular,
                                        design: .rounded
                                    ))
                            }

                    }
                    .listRowBackground(Color.clear)

                }


                // 5) Footer
                FooterVersionRow()
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)

            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(20)
            .scrollContentBackground(.hidden)
            .appScreenStyle(T)
            .alert("Restore Purchases", isPresented: Binding(
                get: { restoreAlert != nil },
                set: { if !$0 { restoreAlert = nil } }
            )) {
                Button("OK", role: .cancel) { restoreAlert = nil }
            } message: {
                Text(restoreAlert ?? "")
            }
            .alert("Delete your account and cloud data?",
                    isPresented: $showDeleteConfirm) {
                 Button("Delete Everything", role: .destructive) {
                     Task {
                         deletingAccount = true
                         deleteError = nil
                         do {
                             try await AccountDeletionService.performFullAccountErasure()
                             // Optional: navigate to signed-out landing, if you have one.
                         } catch {
                             deleteError = error.localizedDescription
                         }
                         deletingAccount = false
                     }
                 }
                 Button("Cancel", role: .cancel) { }
             } message: {
                 Text("This removes your cloud backups, journals, and account, then signs you out. Your on-device Snap Second files remain.")
             }

            .onAppear {
                // Existing setup you already had
                selection = NotificationMode(rawValue: notifModeRaw) ?? .off
                NotificationManager.registerCategories()

                if CloudBackupService.shared.activeBackupId != nil {
                    cloudBackupOn = true
                    backupStatusText = "Active backup running"
                } else {
                    cloudBackupOn = false
                    backupStatusText = "Off"
                }

                progressCancellable = CloudBackupService.shared.progressPublisher
                    .receive(on: DispatchQueue.main)
                    .sink { p in
                        backupTotal = p.total
                        backupDone  = p.done
                        backupState = p.state
                        if p.state == .uploading, p.total > 0 {
                            backupStatusText = "Backing up \(p.done) of \(p.total)…"
                        } else if p.state == .scanning {
                            backupStatusText = "Scanning…"
                        } else if p.state == .finishing {
                            backupStatusText = "Finalizing…"
                        } else if p.state == .restoring, p.total > 0 {
                            backupStatusText = "Restoring \(p.done) of \(p.total)…"
                        } else if p.state == .idle {
                            backupStatusText = cloudBackupOn ? "Active backup running" : "Off"
                        }
                    }

            }
            .alert("Notifications are off",
                   isPresented: $showingAuthTip,
                   actions: {
                       Button("Open Settings") { NotificationManager.openSystemSettings() }
                       Button("Cancel", role: .cancel) {}
                   },
                   message: { Text("Allow notifications for Snap Second in iOS Settings.") })
            .sheet(isPresented: $showingTimeSensitiveSheet) {
                // keep your tip sheet as-is …
                VStack(alignment: .leading, spacing: 16) {
                    Text("Make banners persistent")
                        .font(.system(.title2, design: .rounded).weight(.semibold))
                    Text("Time-Sensitive notifications will always break through Focus. To keep their banners on screen until you swipe them away, set **Banner Style → Persistent** in iOS Settings.")
                        .font(.body)
                        .foregroundStyle(T.textSecondary)
                    Button {
                        NotificationManager.openSystemSettings()
                    } label: {
                        HStack { Spacer(); Text("Open iOS Settings").font(.system(.headline, design: .rounded).weight(.semibold)); Spacer() }
                            .padding(.vertical, 14)
                    }
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    Button("Got it") { showingTimeSensitiveSheet = false }
                        .font(.system(.body, design: .rounded).weight(.semibold))
                        .padding(.top, 8)
                }
                .padding(24)
                .presentationDetents([.height(320), .medium])
            }
            .appScreenStyle(T)
    }

    // MARK: - Helpers

    private func triggerSignInFlow() async {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.keyWindow

        do {
            try await authManager.signInWithApple(
                linkIfAnonymous: true,
                presentingWindow: window
            )
        } catch {
            print("Sign in with Apple failed: \(error.localizedDescription)")
        }
    }


    // MARK: - Mode changes

    private func applyModeChange(_ newValue: NotificationMode) {
        // Persist immediately (no UI lag)
        notifModeRaw = newValue.rawValue
        // Debounced background (re)schedule
        rescheduleDebounced(mode: newValue)

        if newValue == .timeSensitive && !shownTimeSensitiveTip {
            shownTimeSensitiveTip = true
            showingTimeSensitiveSheet = true
        }
    }

    private func rescheduleDebounced(mode: NotificationMode) {
        applyTask?.cancel()
        applying = true
        applyTask = Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            let ok = await NotificationManager.requestAuthorizationIfNeeded()
            if ok {
                NotificationManager.registerCategories()
                await NotificationManager.apply(mode: mode, hour: notifHour, minute: notifMinute)
            } else {
                await MainActor.run { showingAuthTip = true }
            }
            await MainActor.run { applying = false }
        }
    }

    // MARK: - Cloud Backup handlers

    private func handleCloudBackupToggle(_ isOn: Bool) async {
        guard !backupBusy else { return }
        backupBusy = true
        defer { backupBusy = false }

        // ✅ Require Pro
        if isOn && !entitlements.isPro {
            await MainActor.run {
                cloudBackupOn = false
                backupStatusText = "Off"
            }
            PaywallCoordinator.shared.present()
            return
        }

        // ✅ Require account (non-anonymous)
        guard let user = authManager.currentUser, !user.isAnonymous else {
            await MainActor.run {
                cloudBackupOn = false
                backupStatusText = "Off"
                showBackupAuthAlert = true
            }
            return
        }


        // Ensure the service knows the uid (in case app launched before enable)
        do { try await CloudBackupService.shared.enableBackup(for: user.uid) } catch { /* ignore */ }

        if isOn {
            await MainActor.run {
                cloudBackupOn = true
                backupStatusText = "Scanning…"
            }

            if CloudBackupService.shared.activeBackupId != nil {
                // Reuse active session; just kick the scan
                CloudBackupService.shared.performInitialBackupGate() // see next snippet
                return
            }

            do {
                try await CloudBackupService.shared.startNewBackupSession()
                await MainActor.run {
                    backupStatusText = (backupState == .idle) ? "Active backup running" : backupStatusText
                }
            } catch {
                await MainActor.run {
                    cloudBackupOn = false
                    backupStatusText = "Off"
                }
            }
        } else {
            await MainActor.run {
                backupStatusText = "Finishing…"
            }
            await CloudBackupService.shared.endBackupSession()
            await MainActor.run {
                backupStatusText = "Off"
                cloudBackupOn = false
            }
        }
    }

    private var isSignedIn: Bool {
        (authManager.currentUser?.isAnonymous == false)
    }
}


private struct AnonymousRow: View {
    var onSignIn: () -> Void
    private var layoutScale: LayoutScale {
            LayoutScale.forScreenHeight()
        }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Not signed in")
                .font(.system(
                    size: layoutScale.settingsRowBodySize,
                    weight: .semibold,
                    design: .rounded
                ))

            Text("Sign in with Apple to enable Cloud Backup and sync purchases.")
                .font(.system(
                    size: layoutScale.settingsFootnoteSize,
                    weight: .regular,
                    design: .rounded
                ))
                .foregroundStyle(.secondary)
            Button(action: { onSignIn() }) {
                Label("Sign in with Apple", systemImage: "apple.logo")
            }
        }
    }
}




struct BackupsListView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var authManager: AuthManager

    @State private var loading = true
    @State private var errorText: String?
    @State private var backups: [BackupSummary] = []
    @State private var restoringId: String?
    @State private var progressCancellable: AnyCancellable?
    @State private var restoreDone = 0
    @State private var restoreTotal = 0
    @State private var restoreState: BackupState = .idle
    @State private var backupPendingRestore: BackupSummary?
    @State private var didLoadBackups = false
    @State private var wiredProgress  = false

    var body: some View {
        List {
            if loading {
                HStack {
                    ProgressView()
                    Text("Loading backups…")
                }
            } else if let errorText {
                Text(errorText).foregroundStyle(.red)
            } else if backups.isEmpty {
                Text("No backups found").foregroundStyle(.secondary)
            } else {
                Section {
                    ForEach(backups) { b in
                        Button {
                            backupPendingRestore = b
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(b.displayName)
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(.primary)
                                    Text("\(b.displayDate.formatted(date: .abbreviated, time: .shortened)) • \(b.status.capitalized)\(b.deviceName.flatMap({ " • \($0)" }) ?? "")")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text("\(b.clipCount) clips")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                    if restoringId == b.id, restoreTotal > 0 {
                                        Text("Restoring \(restoreDone)/\(restoreTotal)")
                                            .font(.footnote.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        .disabled(restoringId != nil && restoringId != b.id)
                    }
                } header: {
                    Text("Backups").textCase(.none)
                }
            }

            if restoringId != nil, restoreTotal > 0 {
                Section {
                    ProgressView(value: Double(restoreDone), total: Double(restoreTotal))
                    Text("Restoring \(restoreDone) of \(restoreTotal)…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Select a Backup")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Restore from Cloud Backup?",
               isPresented: Binding(
                get: { backupPendingRestore != nil },
                set: { if !$0 { backupPendingRestore = nil } }
               )) {
            Button("Restore", role: .destructive) {
                guard let backup = backupPendingRestore else { return }
                backupPendingRestore = nil
                Task { await startRestore(backup) }
            }
            Button("Cancel", role: .cancel) {
                backupPendingRestore = nil
            }
        } message: {
            Text("Restoring this backup will wipe your current projects and clips on this device before replacing them with the cloud backup.")
        }
        .task {
          if !didLoadBackups {
            didLoadBackups = true
            await loadBackups()
          }
        }
        .onAppear {
          if !wiredProgress {
            wiredProgress = true
            progressCancellable = CloudBackupService.shared.progressPublisher
              .receive(on: DispatchQueue.main)
              .sink { p in
                restoreTotal = p.total
                restoreDone  = p.done
                restoreState = p.state
              }
          }
        }
        .onDisappear { progressCancellable?.cancel() }
    }

    private func loadBackups() async {
        guard let u = authManager.currentUser, !u.isAnonymous else {
            errorText = "Sign in required to view backups."
            loading = false
            return
        }
        do {
            let list = try await CloudBackupService.shared.listBackups(for: u.uid)
            await MainActor.run {
                self.backups = list
                self.loading = false
            }
        } catch {
            await MainActor.run {
                self.errorText = "Failed to load backups."
                self.loading = false
            }
        }
    }

    private func startRestore(_ b: BackupSummary) async {
        restoringId = b.id
        // Show immediate progress state
        await MainActor.run {
            restoreDone = 0
            restoreTotal = 0
            restoreState = .restoring
        }
        ClipStore.shared.deleteAllClips()
        await CloudBackupService.shared.restoreBackup(backupId: b.id, mode: .overwriteAll)
        // When restore finishes, pop back to Settings automatically
        await MainActor.run {
            ClipStore.shared.reloadAfterBulkRestore()
            restoringId = nil
            dismiss()
        }
    }
}

private struct ProMark: View {

    private var layoutScale: LayoutScale {
            LayoutScale.forScreenHeight()
        }

    var body: some View {
        HStack(spacing: 4) {
            Ph.sparkle.fill
                .frame(
                            width: layoutScale.settingsIconSize,
                            height: layoutScale.settingsIconSize
                        )
                .foregroundStyle(.yellow)

            Text("Pro")
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .accessibilityLabel("Pro feature")
    }
}


private struct SubscriptionPromoCard: View {
    let T: Theme
    let isPro: Bool
    var onPrimaryTap: () -> Void
    var onRestore: () -> Void

    @State private var restoring = false
    private var layoutScale: LayoutScale {
            LayoutScale.forScreenHeight()
        }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Primary promo banner
            Button(action: onPrimaryTap) {
                HStack(alignment: .center, spacing: 12) {
                    // App icon / perk icon
                    ZStack {
//                        Circle().fill(.white.opacity(0.18)).frame(width: 36, height: 36)
                        Group {
                            Ph.sparkle.fill
                                .frame(
                                            width: layoutScale.settingsIconSize,
                                            height: layoutScale.settingsIconSize
                                        )
                                .foregroundStyle(.yellow)
                        }
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Snap Second Pro")
                            .font(.system(
                                    size: layoutScale.settingsRowBodySize,
                                    weight: .semibold,
                                    design: .rounded
                                ))
                            .foregroundStyle(.white)

                        Text(isPro ? "Manage your subscription" : "Upgrade for more features")
                            .font(.system(
                                    size: layoutScale.settingsFootnoteSize,
                                    weight: .regular,
                                    design: .rounded
                                ))
                            .foregroundStyle(.white.opacity(0.9))
                    }

                    Spacer(minLength: 0)

                    Ph.caretRight.bold
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .frame(width: 20, height: 20)
                }
                .padding(.vertical, 16)
                .padding(.horizontal, 16)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    T.core.accent,                      // primary brand
                                    T.core.accent.opacity(0.85)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
                .shadow(color: .black.opacity(0.12), radius: 10, x: 0, y: 4)
            }
            .buttonStyle(.plain)

            // Subtle secondary link (restore) under the banner
            Button {
                Task {
                    restoring = true
                    _ = try? await Purchases.shared.restorePurchases()
                    await Entitlements.shared.refreshEntitlements()
                    restoring = false
                }
            } label: {
                HStack(spacing: 6) {
                    if restoring { ProgressView().scaleEffect(0.8) }
                    Text("Restore purchases")
                        .font(.system(
                            size: layoutScale.settingsFootnoteSize,
                            weight: .semibold,
                            design: .rounded
                        ))
                    Spacer()
                }
                .foregroundStyle(T.core.accent)
                .padding(.horizontal, 4)
                .padding(.top, 2)
            }
            .buttonStyle(.plain)
        }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Settings-specific responsive tokens
extension LayoutScale {

    /// Top title "Settings"
    var settingsTitleSize: CGFloat {
        switch self {
        case .small:  return 28     // iPhone mini / SE
        case .medium: return 32     // regular iPhones
        case .large:  return 34     // Max models
        }
    }

    /// Section header titles ("Subscription", "Streaks", "Support")
    var settingsSectionHeaderSize: CGFloat {
        switch self {
        case .small:  return 14
        case .medium: return 16
        case .large:  return 18
        }
    }

    /// Body text (rows)
    var settingsRowBodySize: CGFloat {
        switch self {
        case .small:  return 14
        case .medium: return 16
        case .large:  return 17
        }
    }

    /// Footnote & secondary text
    var settingsFootnoteSize: CGFloat {
        switch self {
        case .small:  return 11
        case .medium: return 12
        case .large:  return 13
        }
    }

    /// Icon size for row icons (Ph.)
    var settingsIconSize: CGFloat {
        switch self {
        case .small:  return 16
        case .medium: return 18
        case .large:  return 20
        }
    }

    /// Vertical card padding
    var settingsCardVerticalPadding: CGFloat {
        switch self {
        case .small:  return 8
        case .medium: return 12
        case .large:  return 14
        }
    }

    /// Row vertical spacing
    var settingsRowVerticalPadding: CGFloat {
        switch self {
        case .small:  return 8
        case .medium: return 12
        case .large:  return 14
        }
    }
}
