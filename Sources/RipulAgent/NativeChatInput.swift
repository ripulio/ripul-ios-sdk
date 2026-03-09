import SwiftUI

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

#if canImport(PhotosUI)
import PhotosUI
#endif

// MARK: - Cross-platform Image Type

#if os(iOS)
public typealias PlatformImage = UIImage
#elseif os(macOS)
public typealias PlatformImage = NSImage
#endif

// MARK: - Image Attachment Model (cross-platform)

/// Model for a native image attachment with a platform-native thumbnail for display.
public struct NativeImageAttachment: Identifiable {
    public let id: String
    public let mediaType: String
    public let data: String // base64
    public let thumbnail: PlatformImage

    public init(id: String, mediaType: String, data: String, thumbnail: PlatformImage) {
        self.id = id
        self.mediaType = mediaType
        self.data = data
        self.thumbnail = thumbnail
    }

    public func toDictionary() -> [String: String] {
        ["id": id, "mediaType": mediaType, "data": data]
    }
}

// MARK: - Cross-platform Chat Input

/// A floating chat input that uses Liquid Glass on iOS 26+ and ultraThinMaterial elsewhere.
/// Includes image attachments and photos picker on both platforms.
/// Camera is iOS-only.
#if os(iOS)
@available(iOS 16.0, *)
public struct NativeChatInput: View {
    @Binding var text: String
    @Binding var imageAttachments: [NativeImageAttachment]
    @Binding var selectedPhotos: [PhotosPickerItem]
    let isAgentRunning: Bool
    let isAgentPaused: Bool
    let onSubmit: () -> Void
    let onPause: (() -> Void)?
    let onNewChat: (() -> Void)?
    let onQuickCommands: (() -> Void)?
    var chatInputGlassStyle: String?
    @State private var showPhotoPicker = false
    @State private var showCamera = false
    @State private var textHeight: CGFloat = 36

    public init(
        text: Binding<String>,
        imageAttachments: Binding<[NativeImageAttachment]>,
        selectedPhotos: Binding<[PhotosPickerItem]>,
        isAgentRunning: Bool = false,
        isAgentPaused: Bool = false,
        onSubmit: @escaping () -> Void,
        onPause: (() -> Void)? = nil,
        onNewChat: (() -> Void)? = nil,
        onQuickCommands: (() -> Void)? = nil,
        chatInputGlassStyle: String? = nil
    ) {
        self._text = text
        self._imageAttachments = imageAttachments
        self._selectedPhotos = selectedPhotos
        self.isAgentRunning = isAgentRunning
        self.isAgentPaused = isAgentPaused
        self.onSubmit = onSubmit
        self.onPause = onPause
        self.onNewChat = onNewChat
        self.onQuickCommands = onQuickCommands
        self.chatInputGlassStyle = chatInputGlassStyle
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
                if onQuickCommands != nil {
                    Button {
                        dismissKeyboard()
                        onQuickCommands?()
                    } label: {
                        Label("Quick Commands", systemImage: "bolt.fill")
                    }
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
                    .frame(width: 40, height: 40)
            }
            .modifier(GlassCircleModifier())

            // Chat bubble
            VStack(spacing: 0) {
                // Image thumbnails row
                if !imageAttachments.isEmpty {
                    imageThumbsRow
                }

                // Text field + send button
                HStack(spacing: 4) {
                    NoAutofillTextView(
                        text: $text,
                        height: $textHeight,
                        placeholder: "Message...",
                        onSubmit: { dismissKeyboard(); onSubmit() }
                    )
                    .frame(height: textHeight)
                    .padding(.leading, 8)
                    .padding(.vertical, 2)

                    let hasContent = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !imageAttachments.isEmpty
                    if isAgentRunning && !isAgentPaused {
                        // Pause button — agent is actively running
                        Button {
                            dismissKeyboard()
                            onPause?()
                        } label: {
                            Image(systemName: "pause.fill")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 34, height: 28)
                                .background(Color.orange, in: Capsule())
                        }
                        .transition(.scale.combined(with: .opacity))
                        .padding(.trailing, 6)
                    } else if isAgentPaused {
                        // Resume button — agent is paused, tap to resume
                        Button {
                            dismissKeyboard()
                            onSubmit()
                        } label: {
                            Image(systemName: "play.fill")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 34, height: 28)
                                .background(Color.green, in: Capsule())
                        }
                        .transition(.scale.combined(with: .opacity))
                        .padding(.trailing, 6)
                    } else if hasContent {
                        // Send button — idle
                        Button {
                            dismissKeyboard()
                            onSubmit()
                        } label: {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 34, height: 28)
                                .background(Color.accentColor, in: Capsule())
                        }
                        .transition(.scale.combined(with: .opacity))
                        .padding(.trailing, 6)
                    }
                }
            }
            .modifier(GlassChatInputBackground(glassStyle: chatInputGlassStyle))
        }
        .animation(.easeInOut(duration: 0.15), value: textHeight)
        .animation(.easeInOut(duration: 0.2), value: text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .animation(.easeInOut(duration: 0.2), value: imageAttachments.count)
        .animation(.easeInOut(duration: 0.2), value: isAgentRunning)
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

    private var imageThumbsRow: some View {
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
}

#elseif os(macOS)

@available(macOS 14.0, *)
public struct NativeChatInput: View {
    @Binding var text: String
    @Binding var imageAttachments: [NativeImageAttachment]
    @Binding var selectedPhotos: [PhotosPickerItem]
    let isAgentRunning: Bool
    let isAgentPaused: Bool
    let onSubmit: () -> Void
    let onPause: (() -> Void)?
    let onNewChat: (() -> Void)?
    let onQuickCommands: (() -> Void)?
    var messageHistory: MessageHistory?
    var chatInputGlassStyle: String?
    @State private var showPhotoPicker = false
    @FocusState private var isFocused: Bool

    public init(
        text: Binding<String>,
        imageAttachments: Binding<[NativeImageAttachment]>,
        selectedPhotos: Binding<[PhotosPickerItem]>,
        isAgentRunning: Bool = false,
        isAgentPaused: Bool = false,
        onSubmit: @escaping () -> Void,
        onPause: (() -> Void)? = nil,
        onNewChat: (() -> Void)? = nil,
        onQuickCommands: (() -> Void)? = nil,
        messageHistory: MessageHistory? = nil,
        chatInputGlassStyle: String? = nil
    ) {
        self._text = text
        self._imageAttachments = imageAttachments
        self._selectedPhotos = selectedPhotos
        self.isAgentRunning = isAgentRunning
        self.isAgentPaused = isAgentPaused
        self.onSubmit = onSubmit
        self.onPause = onPause
        self.onNewChat = onNewChat
        self.onQuickCommands = onQuickCommands
        self.messageHistory = messageHistory
        self.chatInputGlassStyle = chatInputGlassStyle
    }

    public var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            // + menu button outside the chat bubble (iMessage style)
            Menu {
                Button {
                    showPhotoPicker = true
                } label: {
                    Label("Photos", systemImage: "photo")
                }
                if onQuickCommands != nil {
                    Button {
                        onQuickCommands?()
                    } label: {
                        Label("Quick Commands", systemImage: "bolt.fill")
                    }
                }
                Button {
                    onNewChat?()
                } label: {
                    Label("New Chat", systemImage: "plus.bubble")
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 40, height: 40)
            .modifier(GlassCircleModifier())

            // Chat bubble
            VStack(spacing: 0) {
                // Image thumbnails row
                if !imageAttachments.isEmpty {
                    imageThumbsRow
                }

                // Text field + send button
                HStack(spacing: 4) {
                    TextField("Message...", text: $text, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...5)
                        .focused($isFocused)
                        .padding(.leading, 12)
                        .padding(.vertical, 8)
                        .onSubmit {
                            onSubmit()
                        }

                    let hasContent = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !imageAttachments.isEmpty
                    if isAgentRunning && !isAgentPaused {
                        // Pause button — agent is actively running
                        Button {
                            onPause?()
                        } label: {
                            Image(systemName: "pause.fill")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 34, height: 28)
                                .background(Color.orange, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .transition(.scale.combined(with: .opacity))
                        .padding(.trailing, 6)
                    } else if isAgentPaused {
                        // Resume button — agent is paused, tap to resume
                        Button {
                            onSubmit()
                        } label: {
                            Image(systemName: "play.fill")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 34, height: 28)
                                .background(Color.green, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .transition(.scale.combined(with: .opacity))
                        .padding(.trailing, 6)
                    } else if hasContent {
                        // Send button — idle
                        Button {
                            onSubmit()
                        } label: {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 34, height: 28)
                                .background(Color.accentColor, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .transition(.scale.combined(with: .opacity))
                        .padding(.trailing, 6)
                    }
                }
            }
            .frame(minHeight: 40)
            .modifier(GlassChatInputBackground(glassStyle: chatInputGlassStyle))
        }
        .animation(.easeInOut(duration: 0.2), value: text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .animation(.easeInOut(duration: 0.2), value: imageAttachments.count)
        .animation(.easeInOut(duration: 0.2), value: isAgentRunning)
        .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhotos, maxSelectionCount: 4, matching: .images)
        .onAppear {
            isFocused = true
        }
        .onKeyPress(.escape) {
            if isAgentRunning && !isAgentPaused {
                onPause?()
                return .handled
            }
            return .ignored
        }
        .onKeyPress(.upArrow) {
            if let history = messageHistory,
               let previous = history.navigateUp(currentText: text) {
                text = previous
                return .handled
            }
            return .ignored
        }
        .onKeyPress(.downArrow) {
            if let history = messageHistory,
               let next = history.navigateDown() {
                text = next
                return .handled
            }
            return .ignored
        }
    }

    private var imageThumbsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(imageAttachments) { attachment in
                    ZStack(alignment: .topTrailing) {
                        Image(nsImage: attachment.thumbnail)
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
                        .buttonStyle(.plain)
                        .offset(x: 6, y: -6)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)
        }
    }
}

#endif

// MARK: - Glass Background (cross-platform)

@available(iOS 15.0, macOS 14.0, *)
public struct GlassChatInputBackground: ViewModifier {
    public var glassStyle: String? // "regular", "clear", or "identity"

    public init(glassStyle: String? = nil) {
        self.glassStyle = glassStyle
    }

    public func body(content: Content) -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            if glassStyle == "identity" {
                content
            } else {
                let style: Glass = glassStyle == "clear" ? .clear : .regular
                content
                    .background(.clear)
                    .glassEffect(style, in: .rect(cornerRadius: 22))
            }
        } else {
            content
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
        }
        #else
        content
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
        #endif
    }
}

// MARK: - iOS-only: UIKit Text Input & Camera

#if os(iOS)
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
@available(iOS 15.0, *)
struct NoAutofillTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    var placeholder: String
    var onSubmit: () -> Void

    private let minHeight: CGFloat = 36
    private let maxHeight: CGFloat = 120

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
        textView.isScrollEnabled = true
        textView.showsVerticalScrollIndicator = false
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
            textView.layoutIfNeeded()
            context.coordinator.recalcHeight(textView)
        }
    }

    class Coordinator: NSObject, UITextViewDelegate {
        var parent: NoAutofillTextView
        var placeholderLabel: UILabel?

        init(_ parent: NoAutofillTextView) {
            self.parent = parent
        }

        func recalcHeight(_ textView: UITextView) {
            let clamped = min(max(textView.contentSize.height, parent.minHeight), parent.maxHeight)
            if clamped != parent.height {
                DispatchQueue.main.async {
                    self.parent.height = clamped
                }
            }
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            placeholderLabel?.isHidden = !textView.text.isEmpty
            recalcHeight(textView)
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
#endif // os(iOS)
