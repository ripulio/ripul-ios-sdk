import MarkdownUI
import SwiftUI

/// Native sheet for presenting multichoice user interaction questions.
@available(iOS 16.0, macOS 14.0, *)
struct UserInteractionSheet: View {
    let question: UserInteractionQuestion
    let onRespond: (Any) -> Void

    @State private var selectedValues: Set<Int> = []
    @State private var alternativeText = ""
    @FocusState private var isTextFieldFocused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header bar
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .font(.body)

                Spacer()

                Text("Choose an option")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .modifier(GlassCardModifier())

                Spacer()

                if question.multiSelect {
                    Button("Done") {
                        let values = selectedValues.sorted().map { question.options[$0].value }
                        onRespond(values)
                        dismiss()
                    }
                    .font(.body.weight(.semibold))
                    .disabled(selectedValues.isEmpty)
                } else {
                    Button("Cancel") {}
                        .hidden()
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 4)

            ScrollView {
                VStack(spacing: 16) {
                    // Question
                    Markdown(question.question)
                        .markdownTextStyle {
                            FontSize(.em(0.95))
                            ForegroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.top, 8)

                    // Options
                    VStack(spacing: 8) {
                        ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                            let isSelected = selectedValues.contains(index)
                            Button {
                                if question.multiSelect {
                                    toggleSelection(index)
                                } else {
                                    onRespond(option.value)
                                    dismiss()
                                }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(option.label)
                                            .foregroundStyle(.primary)
                                        if let desc = option.description, !desc.isEmpty {
                                            Text(desc)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    if question.multiSelect {
                                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(isSelected ? .blue : .secondary)
                                    } else {
                                        Image(systemName: "chevron.right")
                                            .font(.caption)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .modifier(GlassCardModifier(isSelected: question.multiSelect && isSelected))
                        }
                    }

                    // Alternative text input
                    HStack {
                        TextField("Type an alternative...", text: $alternativeText)
                            .focused($isTextFieldFocused)
                            .onSubmit { submitAlternative() }
                        if !alternativeText.isEmpty {
                            Button {
                                submitAlternative()
                            } label: {
                                Image(systemName: "arrow.up.circle.fill")
                                    .foregroundStyle(.blue)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .modifier(GlassCardModifier())
                }
                .padding(12)
            }
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .modifier(TransparentSheetModifier())
        #else
        .frame(minWidth: 360, minHeight: 300)
        #endif
    }

    private func toggleSelection(_ index: Int) {
        if selectedValues.contains(index) {
            selectedValues.remove(index)
        } else {
            selectedValues.insert(index)
        }
    }

    private func submitAlternative() {
        let text = alternativeText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        onRespond(text)
        dismiss()
    }
}

/// Makes the sheet fully transparent on iOS 26+ so glass cards float directly over the content.
@available(iOS 16.0, *)
private struct TransparentSheetModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .presentationBackground(.clear)
        } else if #available(iOS 16.4, *) {
            content
                .presentationBackground(.ultraThinMaterial)
        } else {
            content
        }
    }
}

/// Rounded-rect glass card background for option groups and input fields.
@available(iOS 15.0, macOS 13.0, *)
private struct GlassCardModifier: ViewModifier {
    var isSelected: Bool = false

    func body(content: Content) -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            content
                .background(.clear)
                .glassEffect(.clear, in: .rect(cornerRadius: 14))
                .tint(isSelected ? Color.blue.opacity(0.3) : nil)
        } else {
            content
                .background(
                    isSelected ? AnyShapeStyle(.blue.opacity(0.15)) : AnyShapeStyle(.ultraThinMaterial),
                    in: RoundedRectangle(cornerRadius: 14)
                )
        }
        #elseif os(macOS)
        if #available(macOS 26.0, *) {
            content
                .background(.clear)
                .glassEffect(.clear, in: .rect(cornerRadius: 14))
                .tint(isSelected ? Color.blue.opacity(0.3) : nil)
        } else {
            content
                .background(
                    isSelected ? AnyShapeStyle(.blue.opacity(0.15)) : AnyShapeStyle(.ultraThinMaterial),
                    in: RoundedRectangle(cornerRadius: 14)
                )
        }
        #endif
    }
}
