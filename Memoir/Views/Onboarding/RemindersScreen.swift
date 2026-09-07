import SwiftUI

struct RemindersScreen: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var T: Theme { AppTheme.sunsetGlow.theme(for: scheme) }
    private var isCondensedLayout: Bool { OnboardingLayout.usesCondensedLayout(verticalSizeClass) }

    @EnvironmentObject private var onboard: OnboardState
    @State private var isRequesting = false

    @AppStorage("notif.mode") private var notifModeRaw: String = NotificationMode.off.rawValue
    @AppStorage("notif.hour") private var notifHour: Int = 12
    @AppStorage("notif.minute") private var notifMinute: Int = 0

    var body: some View {
        OnboardingStepScreen(
            step: .notificationPermission,
            title: "",
            subtitle: "",
            layoutStyle: .minimalCentered
        ) {
            VStack(spacing: isCondensedLayout ? 22 : 28) {
                heroIcon

                Text("Enable daily reminders")
                    .font(OnboardingTypography.fixed(isCondensedLayout ? 28 : 32, weight: .bold))
                    .foregroundStyle(T.core.text)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 340)

                reminderCard
                    .frame(maxWidth: 360)
            }
            .frame(maxWidth: .infinity)
        } footer: {
            VStack(spacing: 12) {
                primaryCTA

                Button(action: goNext) {
                    Text("Not now")
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .foregroundStyle(T.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .disabled(isRequesting)
            }
        }
    }

    private var heroIcon: some View {
        ZStack {
            Circle()
                .fill(T.primaryMuted.opacity(0.9))
                .frame(width: isCondensedLayout ? 110 : 126, height: isCondensedLayout ? 110 : 126)

            Circle()
                .stroke(T.border.opacity(0.85), lineWidth: 1)
                .frame(width: isCondensedLayout ? 110 : 126, height: isCondensedLayout ? 110 : 126)

            Image(systemName: "bell.badge.fill")
                .font(.system(size: isCondensedLayout ? 40 : 46, weight: .semibold))
                .foregroundStyle(T.core.accent)
        }
        .shadow(
            color: scheme == .dark ? .black.opacity(0.24) : .black.opacity(0.08),
            radius: 16,
            y: 8
        )
    }

    private var reminderCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Reminder time")
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .foregroundStyle(T.core.text)

            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Daily")
                        .font(OnboardingTypography.preferred(.headline, weight: .semibold))
                        .foregroundStyle(T.core.text)
                }

                Spacer(minLength: 12)

                Picker("Reminder time", selection: $notifHour) {
                    ForEach(0..<24, id: \.self) { hour in
                        Text(formattedHour(hour)).tag(hour)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(T.core.accent)
            }

            Text("You can change this anytime in Settings.")
                .font(.system(.footnote, design: .rounded))
                .foregroundStyle(T.textSecondary)
        }
        .padding(.horizontal, isCondensedLayout ? 18 : 22)
        .padding(.vertical, isCondensedLayout ? 18 : 22)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(T.surfaceAlt)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(T.border, lineWidth: 1)
        )
    }

    private var primaryCTA: some View {
        Button(action: enableStandardAndContinue) {
            HStack(spacing: 10) {
                if isRequesting {
                    ProgressView()
                        .tint(.white)
                }

                Text("Enable reminders")
                    .font(.system(.headline, design: .rounded).weight(.bold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, isCondensedLayout ? 14 : 16)
        }
        .buttonStyle(.plain)
        .disabled(isRequesting)
        .background(T.core.accent)
        .foregroundStyle(.white)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func formattedHour(_ hour: Int) -> String {
        var comps = DateComponents()
        comps.hour = hour
        comps.minute = 0
        let calendar = Calendar.current
        let date = calendar.date(from: comps) ?? Date()

        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func enableStandardAndContinue() {
        isRequesting = true
        Task {
            let granted = await NotificationManager.requestAuthorizationIfNeeded()
            if granted {
                NotificationManager.registerCategories()

                let hour = notifHour
                let minute = 0

                await MainActor.run {
                    notifModeRaw = NotificationMode.standard.rawValue
                    notifHour = hour
                    notifMinute = minute
                }

                await NotificationManager.apply(
                    mode: .standard,
                    hour: hour,
                    minute: minute
                )
            }

            await MainActor.run {
                isRequesting = false
                onboard.recordNotificationPermission(granted: granted)
                goNext()
            }
        }
    }

    private func goNext() {
        onboard.advance()
    }
}
