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
        NavigationStack {
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
                    VStack(spacing: 2) {
                        ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
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
                                        Image(systemName: selectedValues.contains(index) ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(selectedValues.contains(index) ? .blue : .secondary)
                                    }
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .modifier(GlassCardModifier())

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
            .scrollContentBackground(.hidden)
            .navigationTitle("Choose an option")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                if question.multiSelect {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            let values = selectedValues.sorted().map { question.options[$0].value }
                            onRespond(values)
                            dismiss()
                        }
                        .disabled(selectedValues.isEmpty)
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .modifier(GlassSheetBackgroundModifier())
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

/// Makes the sheet background transparent on iOS 26+ so glass effects show through.
@available(iOS 16.4, macOS 14.0, *)
private struct GlassSheetBackgroundModifier: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            content
                .presentationBackground(.clear)
        } else {
            content
        }
        #else
        content
        #endif
    }
}

/// Rounded-rect glass card background for option groups and input fields.
@available(iOS 15.0, macOS 13.0, *)
private struct GlassCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            content
                .background(.clear)
                .glassEffect(.clear, in: .rect(cornerRadius: 14))
        } else {
            content
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
        #elseif os(macOS)
        if #available(macOS 26.0, *) {
            content
                .background(.clear)
                .glassEffect(.clear, in: .rect(cornerRadius: 14))
        } else {
            content
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
        #endif
    }
}
