import SwiftUI
import UIKit

struct DebugReportView: View {
    @State private var title = ""
    @State private var expectedBehavior = ""
    @State private var actualBehavior = ""
    @State private var reporterNotes = ""
    @State private var screenName = "Estimate"

    @State private var savedIncidentURL: URL?
    @State private var exportFile: ExportFile?
    @State private var errorMessage: String?

    var body: some View {
        NavigationView {
            Form {
                Section("Bug report") {
                    TextField("Title", text: $title)
                    TextField("Screen name", text: $screenName)
                    TextField("Expected behavior", text: $expectedBehavior, axis: .vertical)
                    TextField("Actual behavior", text: $actualBehavior, axis: .vertical)
                    TextField("Notes", text: $reporterNotes, axis: .vertical)
                }

                Section {
                    Button("Save Incident JSON") {
                        do {
                            let screenshot = UIApplication.shared.topMostViewController?.view.snapshotImage()
                            let url = try IncidentWriter.write(
                                title: title,
                                expectedBehavior: expectedBehavior,
                                actualBehavior: actualBehavior,
                                reporterNotes: reporterNotes,
                                screenName: screenName,
                                screenshot: screenshot
                            )
                            savedIncidentURL = url
                            errorMessage = nil
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                }

                if let savedIncidentURL {
                    Section("Saved") {
                        Text("JSON path")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(savedIncidentURL.path)
                            .font(.caption)
                            .textSelection(.enabled)

                        Button("Copy JSON Path") {
                            UIPasteboard.general.string = savedIncidentURL.path
                        }

                        Button("Share JSON") {
                            exportFile = ExportFile(url: savedIncidentURL)
                        }
                    }
                }

                if let errorMessage {
                    Section("Error") {
                        Text(errorMessage).foregroundColor(.red)
                    }
                }
            }
            .navigationTitle("Report Bug")
            .onAppear {
                applyPendingDraftIfNeeded()
            }
            .sheet(item: $exportFile) { exportFile in
                ShareSheet(items: [exportFile.url])
            }
        }
    }

    private func applyPendingDraftIfNeeded() {
        guard let draft = DebugReportDraftStore.shared.consume() else {
            return
        }

        if title.isEmpty {
            title = draft.title
        }
        if expectedBehavior.isEmpty {
            expectedBehavior = draft.expectedBehavior
        }
        if actualBehavior.isEmpty {
            actualBehavior = draft.actualBehavior
        }
        if reporterNotes.isEmpty {
            reporterNotes = draft.reporterNotes
        }
        if screenName.isEmpty || screenName == "Estimate" {
            screenName = draft.screenName
        }
    }
}

private struct ExportFile: Identifiable {
    let id = UUID()
    let url: URL
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

extension UIApplication {
    var topMostViewController: UIViewController? {
        guard let scene = connectedScenes.first as? UIWindowScene,
              let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
            return nil
        }
        return Self.topViewController(from: root)
    }

    private static func topViewController(from controller: UIViewController) -> UIViewController {
        if let nav = controller as? UINavigationController {
            return topViewController(from: nav.visibleViewController ?? nav)
        }
        if let tab = controller as? UITabBarController {
            return topViewController(from: tab.selectedViewController ?? tab)
        }
        if let presented = controller.presentedViewController {
            return topViewController(from: presented)
        }
        return controller
    }
}

extension UIView {
    func snapshotImage() -> UIImage {
        let renderer = UIGraphicsImageRenderer(bounds: bounds)
        return renderer.image { _ in
            drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
    }
}
