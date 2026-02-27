import SwiftUI
import UIKit

#if canImport(PhotosUI)
import PhotosUI
#endif

/// Model for a native image attachment with a UIImage thumbnail for display.
public struct NativeImageAttachment: Identifiable {
    public let id: String
    public let mediaType: String
    public let data: String // base64
    public let thumbnail: UIImage

    public init(id: String, mediaType: String, data: String, thumbnail: UIImage) {
        self.id = id
        self.mediaType = mediaType
        self.data = data
        self.thumbnail = thumbnail
    }

    public func toDictionary() -> [String: String] {
        ["id": id, "mediaType": mediaType, "data": data]
    }
}

/// A Liquid Glass chat input that floats above the web view.
/// Uses PhotosPicker for image attachments and an iMessage-style send button.
@available(iOS 16.0, *)
public struct NativeChatInput: View {
    @Binding var text: String
    @Binding var imageAttachments: [NativeImageAttachment]
    @Binding var selectedPhotos: [PhotosPickerItem]
    let onSubmit: () -> Void
    @FocusState private var isFocused: Bool

    public init(
        text: Binding<String>,
        imageAttachments: Binding<[NativeImageAttachment]>,
        selectedPhotos: Binding<[PhotosPickerItem]>,
        onSubmit: @escaping () -> Void
    ) {
        self._text = text
        self._imageAttachments = imageAttachments
        self._selectedPhotos = selectedPhotos
        self.onSubmit = onSubmit
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Image thumbnails row
            if !imageAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(imageAttachments) { attachment in
                            ZStack(alignment: .topTrailing) {
                                Image(uiImage: attachment.thumbnail)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 56, height: 56)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))

                                Button {
                                    imageAttachments.removeAll { $0.id == attachment.id }
                                    selectedPhotos = []
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 18))
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(.white, .gray)
                                }
                                .offset(x: 6, y: -6)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
                }
            }

            // Input row
            HStack(spacing: 4) {
                PhotosPicker(selection: $selectedPhotos, maxSelectionCount: 4, matching: .images) {
                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                }
                .padding(.leading, 4)

                NoAutofillTextView(
                    text: $text,
                    isFocused: $isFocused,
                    placeholder: "Message...",
                    onSubmit: { isFocused = false; onSubmit() }
                )
                .frame(minHeight: 36, maxHeight: 120)
                .padding(.vertical, 2)

                let hasContent = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !imageAttachments.isEmpty
                if hasContent {
                    Button {
                        isFocused = false
                        onSubmit()
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 28)
                            .background(Color.accentColor, in: Capsule())
                    }
                    .transition(.scale.combined(with: .opacity))
                    .padding(.trailing, 6)
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .animation(.easeInOut(duration: 0.2), value: imageAttachments.count)
        .modifier(GlassChatInputBackground())
    }
}

/// UITextView wrapper that completely disables autofill suggestions.
@available(iOS 15.0, *)
struct NoAutofillTextView: UIViewRepresentable {
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding
    var placeholder: String
    var onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.font = .preferredFont(forTextStyle: .body)
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        textView.textContainer.lineFragmentPadding = 0
        textView.isScrollEnabled = true
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Disable all autofill
        textView.textContentType = .init(rawValue: "")
        textView.autocorrectionType = .yes
        textView.autocapitalizationType = .sentences
        textView.spellCheckingType = .yes
        textView.inputAssistantItem.leadingBarButtonGroups = []
        textView.inputAssistantItem.trailingBarButtonGroups = []

        // Placeholder
        context.coordinator.placeholderLabel = {
            let label = UILabel()
            label.text = placeholder
            label.font = textView.font
            label.textColor = .placeholderText
            label.translatesAutoresizingMaskIntoConstraints = false
            textView.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: textView.leadingAnchor, constant: 4),
                label.topAnchor.constraint(equalTo: textView.topAnchor, constant: 8)
            ])
            return label
        }()

        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        if textView.text != text {
            textView.text = text
        }
        context.coordinator.placeholderLabel?.isHidden = !text.isEmpty

        // Sync focus state
        if isFocused.wrappedValue && !textView.isFirstResponder {
            textView.becomeFirstResponder()
        } else if !isFocused.wrappedValue && textView.isFirstResponder {
            textView.resignFirstResponder()
        }

        // Invalidate intrinsic content size so SwiftUI can resize
        textView.invalidateIntrinsicContentSize()
    }

    class Coordinator: NSObject, UITextViewDelegate {
        var parent: NoAutofillTextView
        var placeholderLabel: UILabel?

        init(_ parent: NoAutofillTextView) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            placeholderLabel?.isHidden = !textView.text.isEmpty
            textView.invalidateIntrinsicContentSize()
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            parent.isFocused.wrappedValue = true
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            parent.isFocused.wrappedValue = false
        }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            // Handle return key as submit (single newline without shift)
            if text == "\n" {
                parent.onSubmit()
                return false
            }
            return true
        }
    }
}

@available(iOS 15.0, *)
struct GlassChatInputBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .background(.clear)
                .glassEffect(.regular, in: .rect(cornerRadius: 22))
        } else {
            content
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
        }
    }
}
