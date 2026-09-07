<p align="center">
  <img src="Memoir/Resources/Assets.xcassets/AppIcon.appiconset/appstore.png" width="120" alt="Snap Second app icon">
</p>

<h1 align="center">Snap Second</h1>

<p align="center"><strong>Turn everyday moments into a film of your life.</strong></p>

<p align="center">
  A native iOS video journal for capturing short moments, organizing them over time,<br>
  and turning them into polished, shareable montages.
</p>

<p align="center">
  <a href="https://apps.apple.com/us/app/snap-second/id6749602215">
    <img src="Memoir/Resources/Assets.xcassets/AppStoreBadge.imageset/AppStoreBadge.svg" alt="Download on the App Store">
  </a>
</p>

> [!NOTE]
> This is a sanitized portfolio edition of the shipped app. Production credentials, private media, and separately licensed production music are intentionally excluded. The private production repository remains the source of truth.

## Product overview

Snap Second brings capture, lightweight editing, calendar-based journaling, memory resurfacing, and video export into one focused experience.

- **Three ways to organize memories:** daily journals, long-running timelapses, and free-form collections.
- **Capture or import:** add photos and videos from the camera or photo library, then trim and frame each moment.
- **Calendar-first storytelling:** browse entries by day, add written reflections, and quickly see where memories were recorded.
- **A full montage editor:** control clip order, date range, music, captions, filters, playback speed, aspect ratio, fit/fill behavior, branding, and export quality.
- **Rewind:** rediscover photos and videos taken on the same date in previous years.
- **Optional cloud backup:** preserve and restore journals and media across devices.
- **Free and Pro experiences:** subscriptions and entitlements are managed through RevenueCat and StoreKit.

## Engineering highlights

This is a production application with a media pipeline, persistence layer, cloud services, and subscription infrastructure—not a UI-only prototype.

- **Custom AVFoundation pipeline** — builds compositions, normalizes source orientation, applies crop/zoom/pan transforms, mixes audio, renders transitions and caption layers, and exports portrait, square, or landscape video.
- **Responsive timeline editing** — asynchronous thumbnail generation, media warm-up, caching, and scrub-aware playback keep the editor interactive as projects grow.
- **Local-first data model** — Core Data stores clip metadata while media is managed on disk; project and journal stores provide purpose-built persistence for their domains.
- **Fast calendar queries** — in-memory indexes support project/day counts and thumbnails without repeatedly scanning the full clip collection.
- **Structured concurrency** — `@MainActor`, actors, task groups, serial workers, and bounded upload work coordinate UI state, file I/O, media processing, and backup.
- **Resilient cloud backup** — Firebase Auth, Firestore, Storage, App Check, batched writes, retry/backoff, hashing, and restore reconciliation support reliable sync.
- **Production observability** — PostHog and Mixpanel cover analytics and experiments, while RevenueCat manages purchases and entitlements.
- **Regression coverage** — Swift Testing exercises calendar behavior across DST boundaries, backup restoration, onboarding sampling, montage behavior, and other data-heavy paths.

## Architecture

| Layer | Responsibilities | Representative code |
| --- | --- | --- |
| SwiftUI feature layer | Navigation, capture, calendars, daily entries, rewind, montage editing, onboarding, and settings | `Memoir/Views/` |
| State and persistence | Projects, clips, journals, entitlements, calendar state, and montage state | `Memoir/Models/` |
| Media engine | Video editing, smart fill, montage composition, playback warm-up, and thumbnails | `Memoir/Helpers/Media/` |
| Service layer | Cloud backup, purchases, authentication, notifications, analytics, and speech-to-text | `Memoir/Helpers/Services/` |
| Backend integration | RevenueCat-to-PostHog webhook forwarding | `backend/revenuecat-posthog-webhook/` |

The app uses a pragmatic SwiftUI architecture: views own presentation state, observable stores own application state, and dedicated services isolate media, persistence, purchases, and network concerns.

## Technology

- Swift, SwiftUI, UIKit, Combine, and Swift Concurrency
- AVFoundation, Photos, PhotosUI, Core Image, and Core Animation
- Core Data and file-based persistence
- Firebase Auth, Firestore, Storage, and App Check
- RevenueCat and StoreKit
- PostHog and Mixpanel
- Rive and Phosphor Icons
- Swift Testing and XCTest UI tests

## Portfolio sanitization

The public edition deliberately differs from production:

- Firebase project configuration and all production integration identifiers are omitted.
- Original onboarding footage and its metadata are replaced by a procedurally generated abstract loop.
- Production music is replaced by one procedurally generated demo track; custom-audio import remains available.
- Build products, downloaded dependencies, compiler caches, local assistant settings, Xcode user state, and `.DS_Store` files are excluded.
- Included fonts retain their SIL Open Font License notices under `LICENSES/`.
- No customer data, signing certificates, provisioning profiles, server credentials, or webhook secrets are included.

## Run locally

### Requirements

- macOS with a current version of Xcode
- iOS 17.6 or later
- An Apple development team for device builds
- A Firebase project for authentication-backed app startup

### Setup

1. Clone this repository and open `Memoir.xcodeproj`.
2. Create an Apple app in your own Firebase project using your chosen bundle identifier.
3. Download Firebase's `GoogleService-Info.plist` and place it at `Memoir/GoogleService-Info.plist`. The included `GoogleService-Info.example.plist` documents the expected shape but is not a working configuration.
4. Select the **Snap Second** scheme and your development team under **Signing & Capabilities**.
5. Allow Xcode to resolve Swift Package Manager dependencies, then press **Run** (`⌘R`).

Analytics keys are blank and therefore analytics are disabled. RevenueCat uses a non-production placeholder until a public SDK key is supplied locally. Camera, photo-library, notification, App Check, purchase, and backup behavior is best validated on a physical device with your own development services.

### Tests

Run the unit and UI test plans with **Product → Test** (`⌘U`), or use a simulator available on your machine:

```bash
xcodebuild \
  -project Memoir.xcodeproj \
  -scheme "Snap Second" \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  test
```

## Repository structure

```text
.
├── Memoir/                 # iOS application source and sanitized resources
│   ├── Helpers/            # Media engines, services, caches, and shared UI
│   ├── Models/             # Domain models, stores, and view models
│   ├── Resources/          # Asset catalog, OFL fonts, and generated demo media
│   └── Views/              # SwiftUI screens grouped by feature
├── MemoirTests/            # Unit and regression tests
├── MemoirUITests/          # End-to-end UI tests
├── Memoir.xcodeproj/       # Xcode project and shared scheme
├── LICENSES/               # Third-party redistribution notices
└── backend/                # Supporting webhook service
```

## Security and privacy

Please see [SECURITY.md](SECURITY.md) before reporting a vulnerability. Never include personal media, credentials, or customer information in a public issue.

## About

Snap Second is designed and developed by [Ryan Zheng](https://github.com/Ryzie2003). Product support and privacy information are available at [snapsecond.co](https://www.snapsecond.co).

## License

The original application source is shared for portfolio review and remains all rights reserved. Third-party components and fonts retain their respective licenses; see [LICENSE](LICENSE) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
