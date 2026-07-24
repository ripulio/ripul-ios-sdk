import SwiftUI
import MarkdownUI

/// Sheet that displays a plan / markdown document. The app renders this with a
/// WKWebView-based markdown view; the SDK renders it with the packaged
/// MarkdownUI dependency so there is no extra web view to carry.
struct PlanSheetView: View {
    let content: String
    let fileName: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Markdown(content)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(fileName.isEmpty ? "Plan" : fileName)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .uiKitIdentifier("PlanSheetView.doneButton")
                }
            }
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
    }
}
