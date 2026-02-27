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

                TextField("Message...", text: $text, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.plain)
                    .focused($isFocused)
                    .onSubmit { isFocused = false; onSubmit() }
                    .padding(.vertical, 10)

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
