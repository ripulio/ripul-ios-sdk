import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// The account photo is the same Clerk image used by teams and shared chats.
@available(iOS 26.0, macOS 26.0, *)
struct RipulProfilePhotoEditor: View {
    let name: String?
    let email: String?
    let baseURL: URL
    let tokenProvider: () -> String?
    let onChange: () -> Void
    @State private var imageURL: URL?
    @State private var hasImage = false
    @State private var busy = false
    @State private var errorMessage: String?
    @State private var selection: PhotosPickerItem?
    @State private var importing = false

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(.tint.opacity(0.15))
                if hasImage, let imageURL {
                    AsyncImage(url: imageURL) { phase in
                        if let image = phase.image { image.resizable().scaledToFill() }
                        else { initials }
                    }
                } else { initials }
            }
            .frame(width: 56, height: 56)
            .clipShape(Circle())
            .accessibilityLabel("Profile photo")
            VStack(alignment: .leading, spacing: 2) {
                Text(name ?? email ?? "Signed in").font(.headline)
                if let email, name != nil { Text(email).font(.subheadline).foregroundStyle(.secondary) }
            }
        }
        .padding(.vertical, 4)
        .task {
            busy = true
            defer { busy = false }
            do { try await request("GET") }
            catch { errorMessage = error.localizedDescription }
        }
        HStack {
            #if os(iOS)
            PhotosPicker(selection: $selection, matching: .images) {
                Label(hasImage ? "Change photo" : "Choose photo", systemImage: "photo")
            }
            .disabled(busy)
            .onChange(of: selection) { _, item in
                guard let item else { return }
                Task {
                    busy = true
                    defer { busy = false; selection = nil }
                    do {
                        guard let data = try await item.loadTransferable(type: Data.self) else { throw PhotoError.invalidImage }
                        try await upload(data)
                    } catch { errorMessage = error.localizedDescription }
                }
            }
            #else
            Button { importing = true } label: {
                Label(hasImage ? "Change photo" : "Choose photo", systemImage: "photo")
            }
            .disabled(busy)
            .fileImporter(isPresented: $importing, allowedContentTypes: [.image]) { result in
                Task {
                    busy = true
                    defer { busy = false }
                    do {
                        let url = try result.get()
                        let access = url.startAccessingSecurityScopedResource()
                        defer { if access { url.stopAccessingSecurityScopedResource() } }
                        try await upload(Data(contentsOf: url))
                    } catch { errorMessage = error.localizedDescription }
                }
            }
            #endif
            Spacer()
            if busy { ProgressView().controlSize(.small) }
            if hasImage {
                Button("Remove photo", role: .destructive) {
                    Task {
                        busy = true
                        defer { busy = false }
                        do { try await request("DELETE"); onChange() }
                        catch { errorMessage = error.localizedDescription }
                    }
                }
                .disabled(busy)
            }
        }
        .buttonStyle(.borderless)
        Text("Your photo appears in your teams and group conversations. Without a photo, your initials appear instead.")
            .font(.caption).foregroundStyle(.secondary)
        if let errorMessage { Text(errorMessage).font(.caption).foregroundStyle(.red) }

    }

    private var initials: some View {
        let words = (name ?? email ?? "?").split(separator: " ")
        let value = words.count > 1
            ? String(words.first!.prefix(1)) + String(words.last!.prefix(1))
            : String(words.first?.prefix(2) ?? "?")
        return Text(value.uppercased()).font(.title3.weight(.semibold)).foregroundStyle(.tint)
    }

    @MainActor private func upload(_ data: Data) async throws {
        guard data.count <= 30 * 1024 * 1024 else { throw PhotoError.tooLarge }
        // Centre crop to a small square before sending camera-sized photos.
        #if os(iOS)
        guard let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else { throw PhotoError.invalidImage }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: CGSize(width: 512, height: 512), format: format).image { _ in
            let scale = 512 / min(image.size.width, image.size.height)
            let width = image.size.width * scale, height = image.size.height * scale
            image.draw(in: CGRect(x: (512 - width) / 2, y: (512 - height) / 2, width: width, height: height))
        }
        guard let jpeg = resized.jpegData(compressionQuality: 0.85) else { throw PhotoError.invalidImage }
        #else
        guard let image = NSImage(data: data), image.size.width > 0, image.size.height > 0,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 512, pixelsHigh: 512,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw PhotoError.invalidImage }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let scale = 512 / min(image.size.width, image.size.height)
        let width = image.size.width * scale, height = image.size.height * scale
        image.draw(in: CGRect(x: (512 - width) / 2, y: (512 - height) / 2, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        guard let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else { throw PhotoError.invalidImage }
        #endif
        try await request("POST", data: jpeg)
        onChange()
    }

    @MainActor private func request(_ method: String, data: Data? = nil) async throws {
        errorMessage = nil
        guard let token = tokenProvider(), !token.isEmpty else { throw PhotoError.signIn }
        guard let url = URL(string: "/api/v1/me/avatar", relativeTo: baseURL) else { throw PhotoError.invalidResponse }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let data {
            request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
            request.httpBody = data
        }
        let (responseData, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              let object = try JSONSerialization.jsonObject(with: responseData) as? [String: Any] else { throw PhotoError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw PhotoError.server(object["error"] as? String ?? "Could not update your photo. Try again.")
        }
        imageURL = (object["imageUrl"] as? String).flatMap(URL.init(string:))
        hasImage = object["hasImage"] as? Bool ?? false
    }

    private enum PhotoError: LocalizedError {
        case signIn, invalidImage, tooLarge, invalidResponse, server(String)
        var errorDescription: String? {
            switch self {
            case .signIn: "Sign in to change your profile photo."
            case .invalidImage: "This image could not be used. Choose another photo."
            case .tooLarge: "Choose a photo smaller than 30 MB."
            case .invalidResponse: "Could not load your profile photo. Try again."
            case .server(let message): message
            }
        }
    }
}
