// MainTabView.swift
import SwiftUI
import Photos
import PhosphorSwift

enum HomeDestination: Hashable {
    case project(UUID)
    case montage(UUID)
    case collections(UUID)  // ✅ NEW: Collections destination
}

final class HomeRouter: ObservableObject {
    @Published var path: NavigationPath

    init(initialProject: Project? = nil) {
        var path = NavigationPath()
        if let initialProject {
            switch initialProject.type {
            case .dailyJournal, .timelapse:
                path.append(HomeDestination.project(initialProject.id))
            case .collections:
                path.append(HomeDestination.collections(initialProject.id))
            }
        }
        self.path = path
    }

    func openProject(_ projectID: UUID) {
        path.removeLast(path.count)
        path.append(HomeDestination.project(projectID))
    }

    func openMontage(_ projectID: UUID) {
        path.removeLast(path.count)
        path.append(HomeDestination.project(projectID))
        path.append(HomeDestination.montage(projectID))
    }

    // ✅ NEW: Open Collections view
    func openCollections(_ projectID: UUID) {
        path.removeLast(path.count)
        path.append(HomeDestination.collections(projectID))
    }

    // keep this if other code calls it
    func openCalendar(_ projectID: UUID) { openProject(projectID) }
}

struct ProTabTrigger: View {
    @EnvironmentObject private var paywall: PaywallCoordinator
    var body: some View {
        // Trigger presentation on the next runloop to avoid same-cycle conflicts
        Color.clear.onAppear {
            DispatchQueue.main.async { paywall.present() }
        }
    }
}

struct MainTabView: View {
    @EnvironmentObject private var onboard: OnboardState
    @EnvironmentObject private var projectStore: ProjectStore
    @EnvironmentObject private var paywall: PaywallCoordinator
    @EnvironmentObject private var entitlements: Entitlements
    @EnvironmentObject private var homeRouter: HomeRouter

    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var scenePhase
    private var T: Theme { AppTheme.sunsetGlow.theme(for: scheme) }

    @State private var selectedTab = 0
    @State private var lastNonProTab = 0

    @State private var showRewindFullScreen = false
    @State private var rewindDaySession: RewindDaySession? = nil
    @State private var isPreparingRewindSession = false
    @State private var shouldPresentRewindWhenReady = false
    @State private var showNoRewindAlert = false
    @State private var rewindResolutionDate: Date? = nil

    // ⬇️ Track restore completion so we can reset Home navigation after a restore
    @State private var wasRestoring = false
    @State private var restoreJustCompleted = false

    @State private var tabBarHeight: CGFloat = 44
    @State private var rewindBadgeCount: Int = 0

    // Bottom safe-area for older SDKs
    private var bottomSafeInset: CGFloat {
        (UIApplication.shared.connectedScenes.first as? UIWindowScene)?
            .keyWindow?.safeAreaInsets.bottom ?? 0
    }

    @State private var proPath       = NavigationPath()
    @State private var settingsPath  = NavigationPath()

    @ViewBuilder private var homeTab: some View {
      NavigationStack(path: $homeRouter.path) {
        ProjectsView(projectStore: projectStore)
          .environmentObject(homeRouter)
          .navigationDestination(for: HomeDestination.self) { dest in
              switch dest {
              case .project(let pid):
                  if let p = projectStore.project(withID: pid) {
                      CalendarView(project: p)
                  }
              case .montage(let pid):
                  if let p = projectStore.project(withID: pid) {
                      MontageView(project: p, T: T)
                  }
              case .collections(let pid):
                  if let p = projectStore.project(withID: pid) {
                      CollectionsView(T: T, project: p)
                  }
              }
          }
      }
    }

    @ViewBuilder private var proTab: some View {
      NavigationStack(path: $proPath) { ProHubView { paywall.present() } }
    }

    @ViewBuilder private var settingsTab: some View {
      NavigationStack(path: $settingsPath) { SettingsView() }
    }

    var body: some View {
      ZStack(alignment: .bottom) {
          GeometryReader { geo in
            ZStack {
              // index 0 → Home
              homeTab
                .frame(width: geo.size.width, height: geo.size.height)
                .offset(x: CGFloat(0 - selectedTab) * geo.size.width)
                .allowsHitTesting(selectedTab == 0)
                .zIndex(selectedTab == 0 ? 1 : 0)

              // index 2 → Pro
              proTab
                .frame(width: geo.size.width, height: geo.size.height)
                .offset(x: CGFloat(2 - selectedTab) * geo.size.width)
                .allowsHitTesting(selectedTab == 2)
                .zIndex(selectedTab == 2 ? 1 : 0)

              // index 3 → Settings
              settingsTab
                .frame(width: geo.size.width, height: geo.size.height)
                .offset(x: CGFloat(3 - selectedTab) * geo.size.width)
                .allowsHitTesting(selectedTab == 3)
                .zIndex(selectedTab == 3 ? 1 : 0)
            }
            .animation(.easeInOut(duration: 0.2), value: selectedTab)
          }
          .padding(.bottom, tabBarHeight)


          BottomTabBar(
              T: T,
              isPro: entitlements.isPro,
              selected: selectedTab,
              select: { newTab in
                  if newTab == 1 {
                      prepareAndPresentRewind()
                      return
                  }

                  withAnimation(.easeInOut(duration: 0.1)) {
                      if newTab == 0 && selectedTab == 0 {
                          // Already on Home tab, so reset to ProjectsView
                          homeRouter.path.removeLast(homeRouter.path.count)
                      }

                      // Normal behavior for non-Rewind tabs
                      selectedTab = newTab
                      if newTab != 2 {
                          lastNonProTab = newTab
                      }
                  }
              },
              rewindBadgeCount: rewindBadgeCount,
              measuredHeight: $tabBarHeight
          )
      }
      .fullScreenCover(isPresented: $showRewindFullScreen) {
          if let session = rewindDaySession {
              RewindDayFullScreenView(
                  session: session,
                  isPresented: $showRewindFullScreen
              )
          }
      }
      .alert("No rewind clips for today", isPresented: $showNoRewindAlert) {
          Button("OK", role: .cancel) {}
      } message: {
          Text("Check back another day to revisit past memories.")
      }
      .task {
          warmRewindIfPossible()
      }
      .onChange(of: scenePhase) { _, newPhase in
          guard newPhase == .active else { return }
          warmRewindIfPossible()
      }
    }

    private func prepareAndPresentRewind() {
        if hasFreshRewindSession {
            presentRewind()
            return
        }

        if hasResolvedRewindForToday && !isPreparingRewindSession {
            showNoRewindAlert = true
            return
        }

        shouldPresentRewindWhenReady = true
        prepareRewindSessionIfNeeded(qos: .userInitiated)
    }

    private var hasFreshRewindSession: Bool {
        guard let rewindDaySession else { return false }
        return Calendar.current.isDate(rewindDaySession.date, inSameDayAs: Date())
    }

    private var hasResolvedRewindForToday: Bool {
        guard let rewindResolutionDate else { return false }
        return Calendar.current.isDate(rewindResolutionDate, inSameDayAs: Date())
    }

    private func warmRewindIfPossible() {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return }

        Task {
            await PhotosWarmup.primeLibrary()
        }
        prepareRewindSessionIfNeeded(qos: .utility)
    }

    private func prepareRewindSessionIfNeeded(qos: DispatchQoS.QoSClass) {
        if let rewindDaySession, !Calendar.current.isDate(rewindDaySession.date, inSameDayAs: Date()) {
            self.rewindDaySession = nil
        }
        if let rewindResolutionDate, !Calendar.current.isDate(rewindResolutionDate, inSameDayAs: Date()) {
            self.rewindResolutionDate = nil
        }

        guard rewindDaySession == nil else {
            if shouldPresentRewindWhenReady {
                shouldPresentRewindWhenReady = false
                presentRewind()
            }
            return
        }

        guard !isPreparingRewindSession else { return }
        isPreparingRewindSession = true

        DispatchQueue.global(qos: qos).async {
            let session = RewindEngine.buildDaySession()

            DispatchQueue.main.async {
                self.isPreparingRewindSession = false
                self.rewindDaySession = session
                self.rewindResolutionDate = Date()

                if let session {
                    RewindPrefetcher.shared.prefetch(session: session)
                }

                if !self.hasOpenedRewindToday() {
                    self.rewindBadgeCount = session?.clips.count ?? 0
                }

                if self.shouldPresentRewindWhenReady {
                    self.shouldPresentRewindWhenReady = false
                    if session != nil {
                        self.presentRewind()
                    } else {
                        self.showNoRewindAlert = true
                    }
                }
            }
        }
    }

    private func presentRewind() {
        showRewindFullScreen = true

        if !hasOpenedRewindToday() {
            rewindBadgeCount = 0
            markRewindOpenedToday()
        }
    }


    private func applyPostOnboardingRouteIfAny() {
        guard let route = onboard.postOnboardingRoute else { return }
        selectedTab = 0
        DispatchQueue.main.async {
            switch route {
            case .calendar(let pid):
                homeRouter.openCalendar(pid)
            case .montage(let pid):
                homeRouter.openMontage(pid)
            }
            onboard.postOnboardingRoute = nil
        }
    }

    private let rewindLastOpenedKey = "com.memoir.rewindLastOpenedDate"

    private func hasOpenedRewindToday() -> Bool {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        if let stored = UserDefaults.standard.object(forKey: rewindLastOpenedKey) as? Date {
            return calendar.isDate(stored, inSameDayAs: today)
        }
        return false
    }

    private func markRewindOpenedToday() {
        UserDefaults.standard.set(Date(), forKey: rewindLastOpenedKey)
    }

}

@MainActor
private final class RewindPrefetcher {
    static let shared = RewindPrefetcher()

    private let manager = PHCachingImageManager()
    private var prefetchedDayKey: String?
    private var prefetchedAssetIDs: Set<String> = []
    private var activeRequestIDs: [String: PHImageRequestID] = [:]

    private init() {}

    func prefetch(session: RewindDaySession) {
        let dayKey = Self.dayKey(for: session.date)
        if prefetchedDayKey != dayKey {
            for requestID in activeRequestIDs.values {
                manager.cancelImageRequest(requestID)
            }
            prefetchedDayKey = dayKey
            prefetchedAssetIDs.removeAll()
            activeRequestIDs.removeAll()
        }

        let scale = UIScreen.main.scale
        let bounds = UIScreen.main.bounds.size
        let targetSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)

        let imageOptions = PHImageRequestOptions()
        imageOptions.isNetworkAccessAllowed = true
        imageOptions.deliveryMode = .highQualityFormat
        imageOptions.resizeMode = .fast

        for clip in session.clips {
            let asset = clip.asset
            guard prefetchedAssetIDs.insert(asset.localIdentifier).inserted else { continue }

            activeRequestIDs[asset.localIdentifier] = manager.requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFit,
                options: imageOptions
            ) { [weak self] _, _ in
                Task { @MainActor in
                    self?.activeRequestIDs.removeValue(forKey: asset.localIdentifier)
                }
            }

            if asset.mediaType == .video {
                let videoOptions = PHVideoRequestOptions()
                videoOptions.isNetworkAccessAllowed = true
                videoOptions.deliveryMode = .highQualityFormat

                activeRequestIDs["video:\(asset.localIdentifier)"] = manager.requestAVAsset(
                    forVideo: asset,
                    options: videoOptions
                ) { [weak self] _, _, _ in
                    Task { @MainActor in
                        self?.activeRequestIDs.removeValue(forKey: "video:\(asset.localIdentifier)")
                    }
                }
            } else if asset.mediaSubtypes.contains(.photoLive) {
                let livePhotoOptions = PHLivePhotoRequestOptions()
                livePhotoOptions.isNetworkAccessAllowed = true

                activeRequestIDs["live:\(asset.localIdentifier)"] = manager.requestLivePhoto(
                    for: asset,
                    targetSize: targetSize,
                    contentMode: .aspectFit,
                    options: livePhotoOptions
                ) { [weak self] _, _ in
                    Task { @MainActor in
                        self?.activeRequestIDs.removeValue(forKey: "live:\(asset.localIdentifier)")
                    }
                }
            }
        }
    }

    private static func dayKey(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

struct BottomTabBar: View {
    var T: Theme
    var isPro: Bool
    var selected: Int
    var select: (Int) -> Void
    var rewindBadgeCount: Int
    var barHeight: CGFloat = 52
    var horizontalPadding: CGFloat = 24
    @Binding var measuredHeight: CGFloat

    private var bottomSafeInset: CGFloat {
        (UIApplication.shared.connectedScenes.first as? UIWindowScene)?
            .keyWindow?.safeAreaInsets.bottom ?? 0
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
                .frame(height: 0.6) // slightly thicker
                .background(T.core.text.opacity(0.15)) // darker


            HStack(spacing: 0) {

                // HOME TAB
                tabButton(
                    title: "Home",
                    isSelected: selected == 0,
                    action: { select(0) }
                ) {
                    (selected == 0 ? Ph.house.fill : Ph.house.bold)
                        .color(selected == 0 ? T.core.accent : T.core.text)
                        .frame(width: 24, height: 24)
                }

                // REWIND TAB
                tabButton(
                    title: "Rewind",
                    isSelected: selected == 1,
                    badgeCount: rewindBadgeCount,
                    action: { select(1) }
                ) {
                    (selected == 1 ? Ph.rewind.fill : Ph.rewind.bold)
                        .color(selected == 1 ? T.core.accent : T.core.text)
                        .frame(width: 24, height: 24)
                }

                // PRO TAB — hide entirely if user is already Pro
                if !isPro {
                    tabButton(
                        title: "Pro",
                        isSelected: selected == 2,
                        action: { PaywallCoordinator.shared.present() }
                    ) {
                        Ph.sparkle.fill
                            .color(Color.yellow)
                            .frame(width: 24, height: 24)
                    }
                }

                // SETTINGS TAB
                tabButton(
                    title: "Settings",
                    isSelected: selected == 3,
                    action: { select(3) }
                ) {
                    (selected == 3 ? Ph.gearSix.fill : Ph.gearSix.bold)
                        .color(selected == 3 ? T.core.accent : T.core.text)
                        .frame(width: 24, height: 24)
                }
            }
            .frame(maxWidth: .infinity)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: selected)
            .frame(height: barHeight)
            .padding(.horizontal, horizontalPadding)
            .background(
                GeometryReader { g in
                    Color.clear
                        .onAppear { measuredHeight = g.size.height }
                        .onChange(of: g.size.height) { measuredHeight = $0 }
                }
            )

        }
        .background(T.core.surface.ignoresSafeArea(edges: .bottom))
    }

    @ViewBuilder
    private func tabButton<Icon: View>(
        title: String,
        isSelected: Bool,
        badgeCount: Int = 0,
        action: @escaping () -> Void,
        @ViewBuilder icon: () -> Icon
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {

                ZStack(alignment: .topTrailing) {
                    icon()

                    if badgeCount > 0 {
                        Text("\(badgeCount)")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(T.core.accent)
                            .clipShape(Circle())
                            .offset(x: 10, y: -6)
                    }
                }

                Text(title)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? T.core.accent : T.core.text)
            }
            .padding(.horizontal, 12)
            .padding(.top, 4)
            .padding(.bottom, 2)
            .frame(maxWidth: .infinity)   // equal widths → centered bar
        }
        .buttonStyle(.plain)
    }
}
