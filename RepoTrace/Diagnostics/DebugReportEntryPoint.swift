import SwiftUI

#if DEBUG
private struct DebugReportEntryPointModifier: ViewModifier {
    @State private var isPresentingDebugReport = false

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isPresentingDebugReport = true
                    } label: {
                        Text("Report Bug")
                    }
                    .accessibilityLabel("Open Debug Report")
                }
            }
            .sheet(isPresented: $isPresentingDebugReport) {
                DebugReportView()
            }
    }
}
#endif

extension View {
    @ViewBuilder
    func repoTraceDebugReportEntryPoint() -> some View {
#if DEBUG
        modifier(DebugReportEntryPointModifier())
#else
        self
#endif
    }
}
