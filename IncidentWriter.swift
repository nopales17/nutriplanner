import Foundation
import UIKit

enum IncidentWriter {
    @MainActor
    static func write(
        title: String,
        expectedBehavior: String,
        actualBehavior: String,
        reporterNotes: String,
        screenName: String,
        screenshot: UIImage?
    ) throws -> URL {
        let id = Self.makeIncidentID()
        let timestamp = ISO8601DateFormatter().string(from: Date())

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"

        let metadata = IncidentMetadata(
            appVersion: version,
            buildNumber: build,
            osVersion: UIDevice.current.systemVersion,
            deviceModel: UIDevice.current.model,
            screenName: screenName,
            gitCommit: Bundle.main.object(forInfoDictionaryKey: "GIT_COMMIT_HASH") as? String,
            timestamp: timestamp
        )

        let screenshotFilename: String?
        let baseDir = try incidentsDirectory()

        if let screenshot {
            let filename = "\(id)-screenshot.jpg"
            let fileURL = baseDir.appendingPathComponent(filename)
            if let data = screenshot.jpegData(compressionQuality: 0.8) {
                try data.write(to: fileURL)
                screenshotFilename = filename
            } else {
                screenshotFilename = nil
            }
        } else {
            screenshotFilename = nil
        }

        let report = IncidentReport(
            id: id,
            title: title,
            expectedBehavior: expectedBehavior,
            actualBehavior: actualBehavior,
            reporterNotes: reporterNotes,
            metadata: metadata,
            breadcrumbs: BreadcrumbStore.shared.snapshot(),
            screenshotFilename: screenshotFilename
        )

        let reportURL = baseDir.appendingPathComponent("\(id).json")
        let data = try JSONEncoder.pretty.encode(report)
        try data.write(to: reportURL)

        return reportURL
    }

    private static func makeIncidentID() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "incident-\(formatter.string(from: Date()))"
    }

    private static func incidentsDirectory() throws -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Incidents", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
