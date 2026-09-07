// Helpers/PerfTimer.swift (new file)

import Foundation

struct PerfTimer {
    private let label: String
    private let start: CFAbsoluteTime

    init(_ label: String) {
        self.label = label
        self.start = CFAbsoluteTimeGetCurrent()
        print("⏱ [\(label)] start")
    }

    func end() {
        let end = CFAbsoluteTimeGetCurrent()
        let delta = (end - start) * 1000
        print("⏱ [\(label)] end: \(String(format: "%.1f", delta)) ms")
    }
}
