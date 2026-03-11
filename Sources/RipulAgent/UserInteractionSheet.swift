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
            List {
                Section {
                    Markdown(question.question)
                        .markdownTextStyle {
                            FontSize(.em(0.95))
                            ForegroundColor(.secondary)
                        }
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }

                Section {
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
                        }
                        .buttonStyle(.plain)
                    }
                }

                Section {
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
                }
            }
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
