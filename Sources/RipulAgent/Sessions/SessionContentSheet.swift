import SwiftUI
import MarkdownUI

/// Displays a session action's Markdown content without creating another web view.
struct SessionContentSheet: View {
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
            .navigationTitle(fileName.isEmpty ? "Content" : fileName)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .uiKitIdentifier("SessionContentSheet.doneButton")
                }
            }
        }
        #if os(iOS)
        .ripulSheet(.page, detents: [.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
    }
}
