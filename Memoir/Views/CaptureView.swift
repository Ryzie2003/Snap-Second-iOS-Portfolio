//
//  CaptureView.swift
//  Memoir
//
//  Created by You on 6/10/25.
//

import SwiftUI
import AVFoundation

extension Notification.Name {
    static let captureDidProduceURL = Notification.Name("captureDidProduceURL")
}

struct CaptureView: View {
    @EnvironmentObject private var store: ClipStore
    let project: Project
    let targetDate: Date
    @Environment(\.dismiss) private var dismiss

    // Bindings from the picker
    @State private var pickedImage: UIImage?
    @State private var pickedVideoURL: URL?
    @State private var isSaving = false
    @State private var isReady = false
    @State private var cameraUnavailable = false

    // Today's date (start of day)
    private var today: Date {
        Calendar.current.startOfDay(for: Date())
    }

    var body: some View {
        ZStack {
            // Black background while camera initializes
            Color.black.ignoresSafeArea()

            if cameraUnavailable {
                VStack(spacing: 16) {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 48))
                        .foregroundColor(.white.opacity(0.6))
                    Text("Camera Unavailable")
                        .font(.headline)
                        .foregroundColor(.white)
                    Button("Dismiss") {
                        dismiss()
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(Color.white.opacity(0.2))
                    .cornerRadius(10)
                }
            } else if isReady {
                CameraPicker(image: $pickedImage, videoURL: $pickedVideoURL)
                    .ignoresSafeArea()
                    .transition(.opacity)
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(1.2)
                    Text("Starting camera...")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.7))
                }
            }

            if isSaving {
                Color.black.opacity(0.4).ignoresSafeArea()
                ProgressView("Saving…")
                    .padding()
                    .background(.ultraThinMaterial)
                    .cornerRadius(8)
            }
        }
        .onAppear {
            // Check camera availability
            guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
                cameraUnavailable = true
                return
            }

            // Longer delay to let nested fullScreenCover animations complete
            // and give UIImagePickerController time to initialize properly
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                withAnimation(.easeIn(duration: 0.2)) {
                    isReady = true
                }
            }
        }
        // When a photo arrives, convert & save
        .onChange(of: pickedImage) { _ in Task { await saveImage() } }
        // When a video arrives, trim & save
        .onChange(of: pickedVideoURL) { _ in Task { await saveVideo() } }
    }

    private func saveImage() async {
        guard let ui = pickedImage else { return }
        await MainActor.run { isSaving = true }

        do {
            // Convert photo → 1s video
            let vidURL = try await ImageToVideoConverter.makeVideo(from: ui, duration: ClipDefaults.duration)
            // Thumbnail
            let thumb = try ThumbnailGenerator.make(from: vidURL, maxLength: 300)
            // Hand off to Calendar → Editor
            NotificationCenter.default.post(
                name: .captureDidProduceURL,
                object: nil,
                userInfo: ["url": vidURL]
            )
        } catch {
            print("CaptureView saveImage error:", error)
        }

        await MainActor.run { isSaving = false; dismiss() }
    }

    private func saveVideo() async {
        guard let url = pickedVideoURL else { return }
        await MainActor.run { isSaving = true }

        do {
            // (Optional) generate a thumb for later use
            _ = try ThumbnailGenerator.make(from: url, maxLength: 300)

            // Hand raw, full-length video to the app
            NotificationCenter.default.post(
                name: .captureDidProduceURL,
                object: nil,
                userInfo: ["url": url]
            )
        } catch {
            print("CaptureView saveVideo error:", error)
        }

        await MainActor.run { isSaving = false; dismiss() }
    }
}

//
//  CameraPicker.swift
//  Memoir
//
//  Created by You on 6/10/25.
//

import SwiftUI
import UIKit
import MobileCoreServices

struct CameraPicker: UIViewControllerRepresentable {
    @Binding var image: UIImage?
    @Binding var videoURL: URL?
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        // Allow both photo & movie capture
        picker.mediaTypes = ["public.image", "public.movie"]
        picker.videoQuality = .typeHigh
        // you can limit duration if you like:
        // picker.videoMaximumDuration = 1.5
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(
          _ picker: UIImagePickerController,
          didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]
        ) {
            // Photo case
            if let uiImage = info[.originalImage] as? UIImage {
                parent.image = uiImage
            }
            // Video case
            if let url = info[.mediaURL] as? URL {
                parent.videoURL = url
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
