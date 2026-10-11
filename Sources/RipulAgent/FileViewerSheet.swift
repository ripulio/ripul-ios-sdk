import SwiftUI

/// Native sheet for viewing file content triggered from tool call renderers.
@available(iOS 16.0, macOS 14.0, *)
struct FileViewerSheet: View {
    let request: FileViewRequest
    @Environment(\.dismiss) private var dismiss

    /// Extract filename from the full path.
    private var fileName: String {
        (request.filePath as NSString).lastPathComponent
    }

    /// Lines of file content, split for line-numbered display.
    private var lines: [String] {
        guard let content = request.content else { return [] }
        return content.components(separatedBy: "\n")
    }

    /// Number of digits in the highest line number, for gutter width.
    private var gutterDigits: Int {
        max(String(lines.count).count, 2)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header bar
            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.ripulIcon(size: 14, weight: .semibold))
                        .foregroundStyle(.ripul(.textSecondary))
                        .frame(width: 32, height: 32)
                        .modifier(InteractiveGlassCircleModifier())
                }

                Spacer()

                Text(fileName)
                    .font(.ripul(.subheadline, weight: .semibold))
                    .lineLimit(1)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .modifier(GlassCardModifier())

                Spacer()

                // Copy path button
                Button {
                    #if os(iOS)
                    UIPasteboard.general.string = request.filePath
                    #elseif os(macOS)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(request.filePath, forType: .string)
                    #endif
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.ripulIcon(size: 14, weight: .semibold))
                        .foregroundStyle(.ripul(.textSecondary))
                        .frame(width: 32, height: 32)
                        .modifier(InteractiveGlassCircleModifier())
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 4)

            // Full path subtitle
            Text(request.filePath)
                .font(.ripul(size: 11, family: .code))
                .foregroundStyle(.ripul(.textSecondary))
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 6)

            Divider()

            // Content area
            if let _ = request.content {
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                            HStack(alignment: .top, spacing: 0) {
                                // Line number gutter
                                Text("\(index + 1)")
                                    .font(.ripul(size: 12, family: .code))
                                    .foregroundStyle(.ripul(.textTertiary))
                                    .frame(width: CGFloat(gutterDigits) * 9 + 12, alignment: .trailing)
                                    .padding(.trailing, 8)

                                // Line content
                                Text(line.isEmpty ? " " : line)
                                    .font(.ripul(size: 12, family: .code))
                                    .foregroundStyle(.ripul(.text))
                                    .textSelection(.enabled)
                            }
                            .padding(.vertical, 1)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                }
            } else {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "doc.text")
                        .font(.ripulIcon(size: 36))
                        .foregroundStyle(.ripul(.textTertiary))
                    Text("File content not available")
                        .font(.ripul(.subheadline))
                        .foregroundStyle(.ripul(.textSecondary))
                    Text("Open from a Read tool call to view content.")
                        .font(.ripul(.caption))
                        .foregroundStyle(.ripul(.textTertiary))
                }
                Spacer()
            }
        }
    }
}
