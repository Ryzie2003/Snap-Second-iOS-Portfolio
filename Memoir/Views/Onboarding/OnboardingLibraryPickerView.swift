import SwiftUI
import Photos

private let _lpDateFormatter: DateFormatter = {
    let df = DateFormatter()
    df.dateStyle = .medium
    return df
}()

private struct SimpleSection: Identifiable {
    let id = UUID()
    let title: String
    let assets: [PHAsset]
}

/// Onboarding-only picker:
/// - Shows All assets grouped by day
/// - Date headers close to the grid
/// - Multi-select with brand highlight
/// - Top-right skip action for continuing without media
struct OnboardingLibraryPickerView: View {
    let project: Project
    @Environment(\.colorScheme) private var scheme
    private var T: Theme { AppTheme.sunsetGlow.theme(for: scheme) }


    @StateObject private var viewModel: LibraryPickerViewModel
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var onboard: OnboardState
    @State private var showSuspense = false
    @State private var suspenseAssets: [PHAsset] = []

    private let gridSpacing: CGFloat = 6

    init(project: Project) {
        self.project = project
        _viewModel = StateObject(wrappedValue: LibraryPickerViewModel(project: project))
    }

    private var selectionCount: Int { viewModel.selectedAssets.count }
    private var canAdd: Bool { selectionCount > 0 && !viewModel.isImporting }
    private var pickerSections: [SimpleSection] {
        viewModel.sections.map { section in
            SimpleSection(
                title: _lpDateFormatter.string(from: section.date),
                assets: section.assets
            )
        }
    }
    private var isPermissionIssue: Bool {
        switch viewModel.authorizationStatus {
        case .denied, .restricted:
            return true
        default:
            return false
        }
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                header
                content
            }
            if showSuspense {
                SuspenseOverlay(assets: suspenseAssets, progress: viewModel.importProgress)
                    .transition(.opacity.combined(with: .scale))
                    .onTapGesture {}
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { bottomCTA }
        .alert("Import Failed",
               isPresented: errorIsPresented) {
            Button("OK") { viewModel.importError = nil }
        } message: {
            Text(viewModel.importError ?? "")
        }
        .background(T.core.surface.ignoresSafeArea())
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                Text("Add to your project")
                    .font(
                        .system(
                            size: OnboardingTypography.scaled(24),
                            weight: .semibold,
                            design: .rounded
                        )
                    )
                    .foregroundStyle(T.core.text)
                    .lineSpacing(2)

                Spacer(minLength: 0)

                Button(action: skipForNow) {
                    Text("Skip")
                        .font(.system(.callout, design: .rounded).weight(.semibold))
                        .foregroundStyle(T.textSecondary)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isImporting)
            }

            Text("Pick photos or videos to instantly add to your project.")
                .font(.system(.callout, design: .rounded))
                .foregroundStyle(T.textSecondary)
        }
        .padding(.horizontal, 32)
        .padding(.top, 20)
        .padding(.bottom, 8)
    }

    // MARK: - Content

    private var content: some View {
        Group {
            if viewModel.isLoadingAssets {
                loadingState
            } else if pickerSections.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(pickerSections, id: \.id) { section in
                            Text(section.title)
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(T.core.text)
                                .padding(.horizontal, 20)
                                .padding(.top, 4)

                            grid(for: section.assets)
                                .padding(.horizontal, 16)
                                .padding(.bottom, 2)
                        }
                        .padding(.top, 6)
                    }
                    .padding(.bottom, selectionCount > 0 ? 96 : 32)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func grid(for assets: [PHAsset]) -> some View {
        let cols = Array(repeating: GridItem(.flexible(), spacing: gridSpacing), count: 3)
        return LazyVGrid(columns: cols, spacing: gridSpacing) {
            ForEach(assets, id: \.localIdentifier) { asset in
                SelectableThumb(asset: asset,
                                selected: $viewModel.selectedAssets,
                                isImporting: viewModel.isImporting,
                                showDayBadge: true,
                                T: T)
            }
        }
        .animation(.easeInOut, value: viewModel.selectedAssets)
    }

    // MARK: - Bottom CTA

    private var bottomCTA: some View {
        Group {
            if selectionCount > 0 {
                Button(action: addSelected) {
                    HStack {
                        if viewModel.isImporting { ProgressView().padding(.trailing, 8) }
                        Text(selectionCount == 1 ? "Add 1 to Project" :
                             "Add \(selectionCount) to Project")
                            .font(.system(.headline, design: .rounded).weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                }
                .disabled(!canAdd)
                .background(T.core.accent)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .padding(.bottom, 16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.easeInOut(duration: 0.2), value: selectionCount)
            }
        }
    }

    private func addSelected() {
        guard canAdd else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        onboard.lastImportLocalIDs = viewModel.selectedAssets.map { $0.localIdentifier }

        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: onboard.lastImportLocalIDs, options: nil)
        var list: [PHAsset] = []
        fetch.enumerateObjects { a,_,_ in list.append(a) }
        suspenseAssets = list.sorted { ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) }
        withAnimation(.easeInOut(duration: 0.2)) { showSuspense = true }

        viewModel.importSelectedAssets(mode: .quickAdd(length: 1.5, trim: true)) { result in
            switch result {
            case .success(let savedCount):
                onboard.onboardingClipsCount = savedCount
                guard savedCount > 0 else {
                    withAnimation(.easeInOut(duration: 0.2)) { showSuspense = false }
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) {
                    onboard.advance()
                    dismiss()
                }
            case .failure:
                withAnimation(.easeInOut(duration: 0.2)) { showSuspense = false }
            }
        }
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
                .tint(T.core.accent)

            Text("Loading your library…")
                .font(.system(.headline, design: .rounded).weight(.semibold))
                .foregroundStyle(T.core.text)

            Text("This can take a moment the first time.")
                .font(.system(.callout, design: .rounded))
                .foregroundStyle(T.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 32)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: isPermissionIssue ? "photo.badge.exclamationmark" : "photo.on.rectangle.angled")
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(T.core.accent)

            Text(isPermissionIssue ? "Photo access is off" : "No photos or videos found")
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .foregroundStyle(T.core.text)
                .multilineTextAlignment(.center)

            Text(emptyStateMessage)
                .font(.system(.callout, design: .rounded))
                .foregroundStyle(T.textSecondary)
                .multilineTextAlignment(.center)

            if isPermissionIssue {
                Button(action: NotificationManager.openSystemSettings) {
                    Text("Open Settings")
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                }
                .background(T.surfaceAlt)
                .foregroundStyle(T.core.text)
                .clipShape(Capsule())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 32)
        .padding(.bottom, 80)
    }

    private var emptyStateMessage: String {
        if isPermissionIssue {
            return "You can continue now and add moments later, or enable Photos access in Settings."
        }
        return "You can continue onboarding now and add your first moment later from your project."
    }

    private func skipForNow() {
        guard !viewModel.isImporting else { return }
        onboard.lastImportLocalIDs = []
        onboard.onboardingClipsCount = 0
        onboard.advance()
    }

    private var errorIsPresented: Binding<Bool> {
        Binding(
            get: { viewModel.importError != nil },
            set: { if !$0 { viewModel.importError = nil } }
        )
    }
}

// MARK: - Selectable Thumb

private struct SelectableThumb: View {
    let asset: PHAsset
    @Binding var selected: Set<PHAsset>
    let isImporting: Bool
    let showDayBadge: Bool
    let T: Theme

    var body: some View {
        GeometryReader { cell in
            AssetThumbnailView(asset: asset)
                .frame(width: cell.size.width, height: cell.size.width)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(selectionOverlay)
                .overlay(dayBadge, alignment: .topLeading)
        }
        .aspectRatio(1, contentMode: .fit)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isImporting else { return }
            toggleSelection(asset)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
        .overlay(typeBadge, alignment: .bottomTrailing)
    }

    private func toggleSelection(_ a: PHAsset) {
        if selected.contains(a) { selected.remove(a) } else { selected.insert(a) }
    }

    private var typeBadge: some View {
        let symbol: String = {
            if asset.mediaType == .video { return "video.fill" }
            if asset.mediaSubtypes.contains(.photoLive) { return "livephoto" }
            return "photo"
        }()

        return Image(systemName: symbol)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white)
            .padding(6)
            .background(.black.opacity(0.65), in: Capsule())
            .padding(6)
            .allowsHitTesting(false)
    }

    private var selectionOverlay: some View {
        Group {
            if selected.contains(asset) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(T.core.primary.opacity(0.22))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(T.core.primary.opacity(0.95), lineWidth: 2)
                    )
                    .overlay(
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(.white)
                            .shadow(radius: 2)
                            .padding(6),
                        alignment: .topTrailing
                    )
            } else {
                Color.clear
            }
        }
        .allowsHitTesting(false)
    }

    private var dayBadge: some View {
        Group {
            if showDayBadge, let d = asset.creationDate {
                let day = Calendar.current.component(.day, from: d)
                Text("\(day)")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.45), in: Capsule())
                    .padding(6)
            }
        }
        .allowsHitTesting(false)
    }
}


private struct SuspenseOverlay: View {
    let assets: [PHAsset]
    let progress: Double

    @State private var offset: CGFloat = 0
    private let thumbSize: CGFloat = 56
    private let spacing: CGFloat = 8

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()

            VStack(spacing: 16) {
                Text("Weaving your moments…")
                    .font(.headline)

                GeometryReader { geo in
                    let width = geo.size.width
                    let count = min(assets.count, 12)
                    let contentWidth = CGFloat(count) * thumbSize + CGFloat(max(0, count-1)) * spacing
                    let needsMarquee = contentWidth > width

                    HStack(spacing: spacing) {
                        ForEach(0..<count, id: \.self) { i in
                            AssetThumbnailView(asset: assets[i])
                                .frame(width: thumbSize, height: thumbSize)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(clipTypeBadge(for: assets[i]), alignment: .bottomTrailing)
                        }
                    }
                    // Force the row to “own” at least the container width so alignment applies
                    .frame(width: max(width, contentWidth),
                           alignment: needsMarquee ? .leading : .center)
                    // Only scroll if we actually overflow
                    .offset(x: needsMarquee ? offset : 0)
                    .onAppear {
                        guard needsMarquee else { return }
                        withAnimation(.linear(duration: 2.0).repeatForever(autoreverses: false)) {
                            offset = -min(contentWidth - width, width * 0.25)
                        }
                    }
                }
                .frame(height: thumbSize)

                ProgressView(value: max(progress, 0.03), total: 1.0)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 220)

                Text("\(Int(progress * 100))%")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(22)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(radius: 10, y: 6)
            .padding(.horizontal, 24)
        }
    }

    private func clipTypeBadge(for asset: PHAsset) -> some View {
        let symbol: String = {
            if asset.mediaType == .video { return "video.fill" }
            if asset.mediaSubtypes.contains(.photoLive) { return "livephoto" }
            return "photo"
        }()
        return Image(systemName: symbol)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white)
            .padding(6)
            .background(.black.opacity(0.65), in: Capsule())
            .padding(5)
            .allowsHitTesting(false)
    }
}
