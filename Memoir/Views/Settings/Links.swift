// Links.swift
import Foundation

enum Links {
    // Keep them absolute, https, lowercase host, no trailing spaces
    static let privacy = URL(string: "https://www.snapsecond.co/privacy")!
    static let terms   = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    static let support = URL(string: "https://www.snapsecond.co/contact")! // or your support page
}
