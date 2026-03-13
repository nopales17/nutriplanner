import Foundation

struct Breadcrumb: Codable {
    let timestamp: String
    let category: String
    let message: String
}

struct IncidentMetadata: Codable {
    let appVersion: String
    let buildNumber: String
    let osVersion: String
    let deviceModel: String
    let screenName: String
    let gitCommit: String?
    let timestamp: String
}

struct IncidentReport: Codable {
    let id: String
    let title: String
    let expectedBehavior: String
    let actualBehavior: String
    let reporterNotes: String
    let metadata: IncidentMetadata
    let breadcrumbs: [Breadcrumb]
    let screenshotFilename: String?
}
