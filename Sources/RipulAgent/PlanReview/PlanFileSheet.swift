import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// The plan's file, whole: the raw markdown source, monospaced and
/// selectable — the document exactly as agent runs read it, with the
/// sectioned review screens' commentary stripped away.
///
/// The copy affordances live here too: the path (for pointing a chat or an
/// editor at the file) and the full contents.
@available(iOS 17.0, macOS 14.0, *)
struct PlanFileSheet: View {
    let path: String
    let contents: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(contents.isEmpty ? "The file contents are not available from this web build." : contents)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .uiKitIdentifier("PlanFileSheet.contents")
            }
            .navigationTitle((path as NSString).lastPathComponent)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            Self.copyToPasteboard(path)
                        } label: {
                            Label("Copy file path", systemImage: "link")
                        }
                        Button {
                            Self.copyToPasteboard(contents)
                        } label: {
                            Label("Copy contents", systemImage: "doc.on.doc")
                        }
                        .disabled(contents.isEmpty)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .uiKitIdentifier("PlanFileSheet.copyMenu")
                }
            }
        }
    }

    static func copyToPasteboard(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}
