//
//  Clip+ZoomCrop.swift
//  Memoir
//
//  Helper extension for zoom/crop functionality
//

import Foundation
import CoreData
import CoreGraphics

// MARK: - Clip Zoom/Crop Helpers

extension Clip {

    /// Returns true if this clip has been zoomed or cropped
    var hasZoomOrCrop: Bool {
        return zoomScale != 1.0 || panOffsetX != 0.0 || panOffsetY != 0.0
    }

    /// Returns the pan offset as a CGPoint for convenience
    var panOffsetPoint: CGPoint {
        get {
            return CGPoint(x: panOffsetX, y: panOffsetY)
        }
        set {
            panOffsetX = newValue.x
            panOffsetY = newValue.y
        }
    }

    /// Resets zoom and crop to default values (no zoom, centered)
    func resetZoomCrop() {
        zoomScale = 1.0
        panOffsetX = 0.0
        panOffsetY = 0.0
    }

    /// Validates and clamps zoom/crop values to safe ranges
    func validateZoomCrop() {
        // Clamp zoom between 1.0 and 3.0
        if zoomScale < 1.0 { zoomScale = 1.0 }
        if zoomScale > 3.0 { zoomScale = 3.0 }

        // Clamp pan offsets between -1.0 and 1.0
        if panOffsetX < -1.0 { panOffsetX = -1.0 }
        if panOffsetX > 1.0 { panOffsetX = 1.0 }
        if panOffsetY < -1.0 { panOffsetY = -1.0 }
        if panOffsetY > 1.0 { panOffsetY = 1.0 }
    }

    /// Returns a transform that represents the zoom/crop as a CGAffineTransform
    /// This can be used for thumbnail generation or preview
    var zoomCropTransform: CGAffineTransform {
        // Apply in order: translate, then scale
        return CGAffineTransform.identity
            .translatedBy(x: panOffsetX * 100, y: panOffsetY * 100)
            .scaledBy(x: zoomScale, y: zoomScale)
    }
}
