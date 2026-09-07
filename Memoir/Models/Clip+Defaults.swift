//
//  Clip+Defaults.swift
//  Memoir
//
//  Convenience accessors for persisted clip defaults.
//

import SwiftUI

extension Clip {
    var previewFillValue: PreviewFill {
        get {
            if let raw = previewFillRaw, let v = PreviewFill(rawValue: raw) {
                return v
            }
            return .portrait
        }
        set {
            previewFillRaw = newValue.rawValue
        }
    }
}
