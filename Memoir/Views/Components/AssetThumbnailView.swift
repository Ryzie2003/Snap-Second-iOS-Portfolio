//
//  AssetThumbnailView.swift
//  Memoir
//
//  Created by Ryan Zheng on 6/9/25.
//

import SwiftUI
import Photos
import UIKit

private func timeString(from seconds: Double) -> String {
    let mins = Int(seconds) / 60
    let secs = Int(seconds) % 60
    return String(format: "%02d:%02d", mins, secs)
}

struct AssetThumbnailView: View {
 let asset: PHAsset
 @State private var image: UIImage?
 @State private var requestID: PHImageRequestID?

 var body: some View {
     ZStack {
         if let img = image {
             Image(uiImage: img)
                 .resizable()
                 .scaledToFill()            // ← fill parent frame
         } else {
             Color(.secondarySystemFill)
         }
     }
     .clipped()
     .onAppear(perform: loadThumbnail)
      .onDisappear {                                // cancel any in‑flight request when off‑screen
          if let id = requestID {
              PHImageManager.default().cancelImageRequest(id)
              requestID = nil
          }
      }
 }

 private func loadThumbnail() {
     // Ask Photos for roughly the on-screen pixel size (fallback if no parent yet)
     let fallbackPoints: CGFloat = 160
      let scale = UIScreen.main.scale
      let target = CGSize(width: fallbackPoints * scale, height: fallbackPoints * scale)
      let options = PHImageRequestOptions()
      options.deliveryMode = .opportunistic  // faster first frames
      options.resizeMode   = .fast
      options.isNetworkAccessAllowed = false // avoid blocking on iCloud
      options.isSynchronous = false
      requestID = PHImageManager.default().requestImage(
          for: asset,
          targetSize: target,
          contentMode: .aspectFill,
          options: options
      ) { result, _ in
          if let img = result {
              self.image = normalized(img)
          }
      }
 }

    private func normalized(_ img: UIImage) -> UIImage {
        if img.imageOrientation == .up { return img }
        UIGraphicsBeginImageContextWithOptions(img.size, false, img.scale)
        img.draw(in: CGRect(origin: .zero, size: img.size))
        let fixed = UIGraphicsGetImageFromCurrentImageContext() ?? img
        UIGraphicsEndImageContext()
        return fixed
    }

}
