//
//  Project.swift
//  Snap Second
//
//  Created by Ryan Zheng on 7/29/25.
//

import Foundation

/// Simple struct for MVP; swap for CoreData later.
struct Project: Identifiable, Equatable, Codable {
    let id: UUID
    var name: String
    var created: Date
    var type: ProjectType

    init(id: UUID = .init(), name: String, created: Date = .init(), type: ProjectType = .dailyJournal) {
        self.id = id
        self.name = name
        self.created = created
        self.type = type
    }

    // MARK: - Codable Migration Support
    enum CodingKeys: String, CodingKey {
        case id, name, created, type
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        created = try container.decode(Date.self, forKey: .created)
        // Default to .dailyJournal if type is missing (for legacy projects)
        type = try container.decodeIfPresent(ProjectType.self, forKey: .type) ?? .dailyJournal
    }
}
// MARK: - ProjectType

enum ProjectType: String, Codable, CaseIterable, Identifiable {
    case dailyJournal = "dailyJournal"
    case timelapse = "timelapse"
    case collections = "collections"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .dailyJournal: return "Daily Journal"
        case .timelapse: return "Timelapse"
        case .collections: return "Collections"
        }
    }

    var icon: String {
        switch self {
        case .dailyJournal: return "calendar.badge.clock"
        case .timelapse: return "film.stack"
        case .collections: return "square.grid.2x2"
        }
    }

    var subtitle: String {
        switch self {
        case .dailyJournal:
            return "Capture a short daily entry with text and clips."
        case .timelapse:
            return "Add clips over time to stitch into a seamless montage."
        case .collections:
            return "Organize any clips you want—no timeline required."
        }
    }
}
