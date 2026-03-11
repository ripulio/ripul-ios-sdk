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
                // Close button — glass circle with X icon
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                        .modifier(InteractiveGlassCircleModifier())
                }

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
                    // Invisible spacer to balance layout
                    Color.clear.frame(width: 32, height: 32)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 4)

            ScrollView {
                VStack(spacing: 8) {
                    // Question
                    Markdown(question.question)
                        .markdownTextStyle {
                            FontSize(.em(0.95))
                            ForegroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                        .padding(.top, 8)
                        .padding(.bottom, 8)

                    // Options — each is an interactive glass button
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
                            HStack(spacing: 12) {
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
                                        .font(.title3)
                                        .foregroundStyle(isSelected ? .blue : .secondary)
                                } else {
                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .modifier(InteractiveGlassCardModifier(isSelected: question.multiSelect && isSelected))
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
                                    .font(.title3)
                                    .foregroundStyle(.blue)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .modifier(GlassCardModifier())
                }
                .padding(12)
            }
        }
        .modifier(GlassSheetBackground())
        #if os(iOS)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .modifier(ClearSheetModifier())
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

/// Puts a full-bleed glass rectangle behind the sheet content on iOS 26+.
@available(iOS 15.0, macOS 13.0, *)
private struct GlassSheetBackground: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            content
                .background {
                    Color.clear
                        .ignoresSafeArea()
                        .glassEffect(.clear, in: .rect)
                }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

/// Clears the system sheet background on iOS 26+ so our glass shows through.
@available(iOS 16.0, *)
private struct ClearSheetModifier: ViewModifier {
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

/// Static glass card (for title pill and text input).
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

/// Interactive glass card for option buttons — has press feedback.
@available(iOS 15.0, macOS 13.0, *)
private struct InteractiveGlassCardModifier: ViewModifier {
    var isSelected: Bool = false

    func body(content: Content) -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            content
                .background(.clear)
                .glassEffect(.clear.interactive(), in: .rect(cornerRadius: 14))
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
                .glassEffect(.clear.interactive(), in: .rect(cornerRadius: 14))
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

/// Interactive glass circle for the close button.
@available(iOS 15.0, macOS 13.0, *)
private struct InteractiveGlassCircleModifier: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            content
                .background(.clear)
                .glassEffect(.clear.interactive(), in: .circle)
        } else {
            content
                .background(.ultraThinMaterial, in: Circle())
        }
        #elseif os(macOS)
        if #available(macOS 26.0, *) {
            content
                .background(.clear)
                .glassEffect(.clear.interactive(), in: .circle)
        } else {
            content
                .background(.ultraThinMaterial, in: Circle())
        }
        #endif
    }
}
