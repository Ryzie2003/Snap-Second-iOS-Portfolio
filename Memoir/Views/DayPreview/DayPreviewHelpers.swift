//
//  DayPreviewHelpers.swift
//  Snap Second
//
//  Helper views and utilities for DayPreviewView
//

import SwiftUI
import AVFoundation
import Photos
import PhotosUI
import UniformTypeIdentifiers

// MARK: - Editor Item

struct EditorItem: Identifiable {
    let id = UUID()
    let initialURL: URL?
    let editingClip: Clip?
    let sourceLocalID: String?
}

// MARK: - Preview Fill

enum PreviewFill: String, CaseIterable, Identifiable {
    case portrait, landscape, square
    var id: String { rawValue }
    var aspect: CGFloat {
        switch self {
        case .portrait:  return 9.0/16.0
        case .landscape: return 16.0/9.0
        case .square:    return 1.0
        }
    }
    var label: String {
        switch self {
        case .portrait:  return "Portrait"
        case .landscape: return "Landscape"
        case .square:    return "1×1"
        }
    }
}

// MARK: - Media Payload

enum MediaPayload {
    case photo(url: URL)
    case video(url: URL, avAsset: AVAsset)
}

// MARK: - Media Kind

enum MediaKind { case video, livePhoto, image }

func mediaKind(for asset: PHAsset) -> MediaKind {
    if asset.mediaType == .video { return .video }
    if asset.mediaSubtypes.contains(.photoLive) { return .livePhoto }
    return .image
}

// MARK: - Fetch for Editing

func withMediaPreparationTimeout<T>(
    seconds: TimeInterval = 90,
    operation: @escaping () async throws -> T
) async throws -> T {
    let race = MediaPreparationTimeoutRace<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            race.start(
                continuation: continuation,
                seconds: seconds,
                operation: operation
            )
        }
    } onCancel: {
        race.cancel()
    }
}

private final class MediaPreparationTimeoutRace<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var operationTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var didFinish = false

    func start(
        continuation: CheckedContinuation<T, Error>,
        seconds: TimeInterval,
        operation: @escaping () async throws -> T
    ) {
        lock.lock()
        if didFinish {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        lock.unlock()

        let operationTask = Task {
            do {
                let result = try await operation()
                finish(.success(result))
            } catch {
                finish(.failure(error))
            }
        }

        let timeoutTask = Task {
            do {
                let nanoseconds = UInt64(max(0, seconds) * 1_000_000_000)
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }

            operationTask.cancel()
            finish(.failure(NSError(
                domain: "MediaPreparation",
                code: -1001,
                userInfo: [NSLocalizedDescriptionKey: "Timed out downloading from iCloud."]
            )))
        }

        lock.lock()
        if didFinish {
            lock.unlock()
            operationTask.cancel()
            timeoutTask.cancel()
        } else {
            self.operationTask = operationTask
            self.timeoutTask = timeoutTask
            lock.unlock()
        }
    }

    func cancel() {
        let continuation: CheckedContinuation<T, Error>?
        let operationTask: Task<Void, Never>?
        let timeoutTask: Task<Void, Never>?

        lock.lock()
        guard !didFinish else {
            lock.unlock()
            return
        }
        didFinish = true
        continuation = self.continuation
        operationTask = self.operationTask
        timeoutTask = self.timeoutTask
        self.continuation = nil
        self.operationTask = nil
        self.timeoutTask = nil
        lock.unlock()

        operationTask?.cancel()
        timeoutTask?.cancel()
        continuation?.resume(throwing: CancellationError())
    }

    private func finish(_ result: Result<T, Error>) {
        let continuation: CheckedContinuation<T, Error>?
        let timeoutTask: Task<Void, Never>?

        lock.lock()
        guard !didFinish else {
            lock.unlock()
            return
        }
        didFinish = true
        continuation = self.continuation
        timeoutTask = self.timeoutTask
        self.continuation = nil
        self.operationTask = nil
        self.timeoutTask = nil
        lock.unlock()

        timeoutTask?.cancel()
        switch result {
        case .success(let value):
            continuation?.resume(returning: value)
        case .failure(let error):
            continuation?.resume(throwing: error)
        }
    }
}

@MainActor
func fetchForEditing(
    asset: PHAsset,
    onProgress: @escaping (Double) -> Void,
    onRequestID: @escaping (PHImageRequestID) -> Void = { _ in },
    onResourceRequestID: @escaping (PHAssetResourceDataRequestID) -> Void = { _ in }
) async throws -> MediaPayload {

    if asset.mediaSubtypes.contains(.photoLive) {
        let resources = PHAssetResource.assetResources(for: asset)
        if let paired = resources.first(where: { $0.type == .pairedVideo }) {
            let out = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")

            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                let opts = PHAssetResourceRequestOptions()
                opts.isNetworkAccessAllowed = true
                opts.progressHandler = { p in DispatchQueue.main.async { onProgress(p) } }

                do {
                    if !FileManager.default.fileExists(atPath: out.path) {
                        FileManager.default.createFile(atPath: out.path, contents: nil)
                    }
                    let handle = try FileHandle(forWritingTo: out)

                    var rid: PHAssetResourceDataRequestID?
                    rid = PHAssetResourceManager.default().requestData(
                        for: paired,
                        options: opts,
                        dataReceivedHandler: { chunk in
                            do {
                                try handle.seekToEnd()
                                try handle.write(contentsOf: chunk)
                            } catch {
                                if let rid { PHAssetResourceManager.default().cancelDataRequest(rid) }
                                cont.resume(throwing: error)
                            }
                        },
                        completionHandler: { error in
                            do { try handle.close() } catch { }
                            if let error { cont.resume(throwing: error) }
                            else { cont.resume(returning: ()) }
                        }
                    )
                    if let rid { onResourceRequestID(rid) }
                } catch {
                    cont.resume(throwing: error)
                }
            }
            return .video(url: out, avAsset: AVURLAsset(url: out))
        }
    }

    if asset.mediaType == .image {
        return try await withCheckedThrowingContinuation { cont in
            let o = PHImageRequestOptions()
            o.isSynchronous = false
            o.deliveryMode  = .highQualityFormat
            o.isNetworkAccessAllowed = true
            o.progressHandler = { p,_,_,_ in DispatchQueue.main.async { onProgress(p) } }

            let rid = PHImageManager.default().requestImageDataAndOrientation(for: asset, options: o) { data, _, _, info in
                if let cancelled = info?[PHImageCancelledKey] as? NSNumber, cancelled.boolValue {
                    return cont.resume(throwing: CancellationError())
                }
                if let err = info?[PHImageErrorKey] as? Error { return cont.resume(throwing: err) }
                guard let data = data else { return cont.resume(throwing: NSError(domain: "fetch", code: -1)) }
                let url = URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension("jpg")
                do { try data.write(to: url); cont.resume(returning: .photo(url: url)) }
                catch { cont.resume(throwing: error) }
            }
            onRequestID(rid)
        }
    } else {
        return try await withCheckedThrowingContinuation { cont in
            let o = PHVideoRequestOptions()
            o.deliveryMode = .automatic
            o.isNetworkAccessAllowed = true
            o.progressHandler = { p,_,_,_ in DispatchQueue.main.async { onProgress(p) } }

            let rid = PHImageManager.default().requestAVAsset(forVideo: asset, options: o) { av, _, info in
                if let cancelled = info?[PHImageCancelledKey] as? NSNumber, cancelled.boolValue {
                    return cont.resume(throwing: CancellationError())
                }
                if let err = info?[PHImageErrorKey] as? Error { return cont.resume(throwing: err) }
                guard let av else {
                    return cont.resume(throwing: NSError(domain: "fetch", code: -2))
                }
                if let urlAsset = av as? AVURLAsset {
                    return cont.resume(returning: .video(url: urlAsset.url, avAsset: urlAsset))
                }
                Task {
                    do {
                        let url = try await exportVideoAssetForEditing(av)
                        cont.resume(returning: .video(url: url, avAsset: AVURLAsset(url: url)))
                    } catch {
                        cont.resume(throwing: error)
                    }
                }
            }
            onRequestID(rid)
        }
    }
}

private func exportVideoAssetForEditing(_ asset: AVAsset) async throws -> URL {
    let presets = AVAssetExportSession.exportPresets(compatibleWith: asset)
    let preset = presets.contains(AVAssetExportPresetPassthrough)
        ? AVAssetExportPresetPassthrough
        : AVAssetExportPresetHighestQuality

    guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
        throw NSError(domain: "fetch", code: -3)
    }

    let out = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("mov")

    session.outputURL = out
    session.outputFileType = .mov

    return try await withCheckedThrowingContinuation { cont in
        session.exportAsynchronously {
            if session.status == .completed {
                cont.resume(returning: out)
            } else {
                cont.resume(throwing: session.error ?? NSError(domain: "fetch", code: -4))
            }
        }
    }
}

// MARK: - PHPicker One

struct PHPickerOne: UIViewControllerRepresentable {
    struct Picked { let url: URL; let localIdentifier: String? }
    var onPicked: (Picked?) -> Void
    func makeCoordinator() -> Coord { Coord(onPicked: onPicked) }
    func makeUIViewController(context: Context) -> PHPickerViewController {
        var c = PHPickerConfiguration(photoLibrary: .shared())
        c.selectionLimit = 1
        c.filter = .any(of: [.videos, .images])
        c.preferredAssetRepresentationMode = .current
        let vc = PHPickerViewController(configuration: c)
        vc.delegate = context.coordinator
        return vc
    }
    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    final class Coord: NSObject, PHPickerViewControllerDelegate {
        let onPicked: (Picked?) -> Void
        init(onPicked: @escaping (Picked?) -> Void) { self.onPicked = onPicked }
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            defer { picker.dismiss(animated: true) }
            guard let r = results.first else { onPicked(nil); return }
            let localID = r.assetIdentifier
            let type = r.itemProvider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) ? UTType.movie.identifier : UTType.image.identifier
            r.itemProvider.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
                guard let src = url else { DispatchQueue.main.async { self.onPicked(nil) }; return }
                let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pick-\(UUID().uuidString)").appendingPathExtension(type == UTType.movie.identifier ? "mp4" : "jpg")
                try? FileManager.default.removeItem(at: tmp)
                do { try FileManager.default.copyItem(at: src, to: tmp) } catch { DispatchQueue.main.async { self.onPicked(nil) }; return }
                DispatchQueue.main.async {
                    self.onPicked(Picked(url: tmp, localIdentifier: localID))
                }
            }
        }
    }
}
