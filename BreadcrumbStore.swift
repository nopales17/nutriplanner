import Foundation

@MainActor
final class BreadcrumbStore: ObservableObject {
    static let shared = BreadcrumbStore()

    @Published private(set) var items: [Breadcrumb] = []
    private let maxItems = 50

    private init() {}

    func add(_ message: String, category: String = "ui") {
        let crumb = Breadcrumb(
            timestamp: ISO8601DateFormatter().string(from: Date()),
            category: category,
            message: message
        )
        items.append(crumb)
        if items.count > maxItems {
            items.removeFirst(items.count - maxItems)
        }
    }

    func snapshot() -> [Breadcrumb] {
        items
    }

    func clear() {
        items.removeAll()
    }
}
