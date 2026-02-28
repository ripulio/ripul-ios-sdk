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
    let onNewChat: (() -> Void)?
    @State private var showPhotoPicker = false
    @State private var showCamera = false

    public init(
        text: Binding<String>,
        imageAttachments: Binding<[NativeImageAttachment]>,
        selectedPhotos: Binding<[PhotosPickerItem]>,
        onSubmit: @escaping () -> Void,
        onNewChat: (() -> Void)? = nil
    ) {
        self._text = text
        self._imageAttachments = imageAttachments
        self._selectedPhotos = selectedPhotos
        self.onSubmit = onSubmit
        self.onNewChat = onNewChat
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    public var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            // + menu button outside the chat bubble (iMessage style)
            Menu {
                Button {
                    showCamera = true
                } label: {
                    Label("Camera", systemImage: "camera")
                }
                Button {
                    showPhotoPicker = true
                } label: {
                    Label("Photos", systemImage: "photo")
                }
                Button {
                    dismissKeyboard()
                    onNewChat?()
                } label: {
                    Label("New Chat", systemImage: "plus.bubble")
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
            }
            .modifier(GlassChatInputBackground())

            // Chat bubble
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

                // Text field + send button
                HStack(spacing: 4) {
                    NoAutofillTextView(
                        text: $text,
                        placeholder: "Message...",
                        onSubmit: { dismissKeyboard(); onSubmit() }
                    )
                    .frame(minHeight: 36, maxHeight: 120)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 8)
                    .padding(.vertical, 2)

                    let hasContent = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !imageAttachments.isEmpty
                    if hasContent {
                        Button {
                            dismissKeyboard()
                            onSubmit()
                        } label: {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 28, height: 28)
                                .background(Color.accentColor, in: Circle())
                        }
                        .transition(.scale.combined(with: .opacity))
                        .padding(.trailing, 6)
                    }
                }
            }
            .modifier(GlassChatInputBackground())
        }
        .animation(.easeInOut(duration: 0.2), value: text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .animation(.easeInOut(duration: 0.2), value: imageAttachments.count)
        .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhotos, maxSelectionCount: 4, matching: .images)
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { uiImage in
                if let jpeg = uiImage.jpegData(compressionQuality: 0.8) {
                    let base64 = jpeg.base64EncodedString()
                    let id = "img_\(Int(Date().timeIntervalSince1970 * 1000))_\(Int.random(in: 0..<100000))"
                    imageAttachments.append(NativeImageAttachment(id: id, mediaType: "image/jpeg", data: base64, thumbnail: uiImage))
                }
            }
            .ignoresSafeArea()
        }
    }
}

/// UITextView subclass that suppresses the iOS autofill toolbar above the keyboard.
class ChatTextView: UITextView {
    override var textContentType: UITextContentType! {
        get { nil }
        set { }
    }

    // Replace the system autofill toolbar with an invisible empty view
    private let _emptyAccessory: UIView = {
        let v = UIView(frame: .zero)
        v.isHidden = true
        return v
    }()

    override var inputAccessoryView: UIView? {
        get { _emptyAccessory }
        set { }
    }

    override func buildMenu(with builder: any UIMenuBuilder) {
        if #available(iOS 17.0, *) {
            builder.remove(menu: .autoFill)
        }
        super.buildMenu(with: builder)
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        let name = NSStringFromSelector(action)
        if name.lowercased().contains("autofill") {
            return false
        }
        return super.canPerformAction(action, withSender: sender)
    }
}

/// UITextView wrapper that completely disables autofill suggestions.
/// Uses isScrollEnabled = false so intrinsic content size matches text,
/// starting at single-line height and growing up to the SwiftUI frame max.
@available(iOS 15.0, *)
struct NoAutofillTextView: UIViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> ChatTextView {
        let textView = ChatTextView()
        textView.delegate = context.coordinator
        textView.font = .preferredFont(forTextStyle: .body)
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
        textView.textContainer.lineFragmentPadding = 0
        textView.isScrollEnabled = false
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        textView.autocorrectionType = .yes
        textView.autocapitalizationType = .sentences
        textView.spellCheckingType = .yes
        textView.inputAssistantItem.leadingBarButtonGroups = []
        textView.inputAssistantItem.trailingBarButtonGroups = []

        // Placeholder
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
        context.coordinator.placeholderLabel = label

        return textView
    }

    func updateUIView(_ textView: ChatTextView, context: Context) {
        if textView.text != text {
            textView.text = text
            context.coordinator.placeholderLabel?.isHidden = !text.isEmpty
        }
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

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            if text == "\n" {
                parent.onSubmit()
                return false
            }
            return true
        }
    }
}

/// Wraps UIImagePickerController for camera capture.
@available(iOS 15.0, *)
struct CameraPicker: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss
    var onCapture: (UIImage) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker

        init(_ parent: CameraPicker) {
            self.parent = parent
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage {
                parent.onCapture(image)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
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
