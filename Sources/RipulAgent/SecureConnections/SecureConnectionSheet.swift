import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Entry point shared by chat links, shortcuts, native tool cards and the app's
/// browser. The capture URL is only a write capability; the key never crosses it.
@MainActor
public enum RipulSecureConnection {
    static let didSave = Notification.Name("ripul.secureConnection.saved")

    @discardableResult
    public static func open(_ url: URL) -> Bool {
        #if os(iOS)
        return open(url, in: nil)
        #else
        return false
        #endif
    }

    #if os(iOS)
    private static var active: SecureConnectionPresentation?

    @discardableResult
    public static func open(_ url: URL, in window: UIWindow?) -> Bool {
        guard SecureConnectionRequest.recognizes(url) else { return false }
        if active != nil { return true }
        guard let window = window ?? RipulChrome.appWindow(),
              let root = window.rootViewController else { return false }
        let presentation = SecureConnectionPresentation(url: url)
        active = presentation
        presentation.finished = { [weak presentation] in
            if active === presentation { active = nil }
        }
        presentation.present(from: root)
        return true
    }
    #endif
}

#if os(iOS)
@MainActor
private final class SecureConnectionPresentation: NSObject, UIAdaptivePresentationControllerDelegate {
    private let model: SecureConnectionModel
    private var protection: UUID?
    private weak var controller: UIViewController?
    var finished: (() -> Void)?

    init(url: URL) {
        model = SecureConnectionModel(request: SecureConnectionRequest(url: url))
        super.init()
    }

    func present(from root: UIViewController) {
        protection = SecureInputProtection.begin()
        // Stop existing capture before a single character can be entered.
        LiveStreamHost.shared.pauseForSecureInput()
        RipulViewExplorer.dismiss()
        VoiceModePresence.shared.controller?.stop()
        var presenter = root
        while let child = presenter.presentedViewController, !child.isBeingDismissed { presenter = child }
        presenter.view.endEditing(true)
        let sheet = SecureConnectionHost(rootView: AnyView(
            SecureConnectionSheet(model: model, close: { [weak self] in self?.close() }).ripulThemeRoot()
        ))
        sheet.modalPresentationStyle = .pageSheet
        sheet.sheetPresentationController?.detents = [.large()]
        sheet.sheetPresentationController?.prefersGrabberVisible = true
        sheet.onDismiss = { [weak self] in self?.finish() }
        controller = sheet
        presenter.present(sheet, animated: true)
        sheet.presentationController?.delegate = self
        model.savingChanged = { [weak sheet] saving in sheet?.isModalInPresentation = saving }
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { finish() }

    private func close() {
        guard !model.saving else { return }
        model.clearKey()
        controller?.dismiss(animated: true) { [weak self] in self?.finish() }
    }

    private func finish() {
        model.cancel()
        if let protection { SecureInputProtection.end(protection); self.protection = nil }
        finished?()
        finished = nil
    }
}

@MainActor
private final class SecureConnectionHost: UIHostingController<AnyView> {
    var onDismiss: (() -> Void)?
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if presentingViewController == nil { onDismiss?() }
    }
}

@MainActor
private final class SecureConnectionModel: ObservableObject {
    @Published var details: SecureConnectionDetails?
    @Published var key = ""
    @Published var access: SecureConnectionAccess = .stored
    @Published var origin = ""
    @Published var loading = true
    @Published var saving = false
    @Published var saved = false
    @Published var error: String?
    @Published var unavailable = false
    var savingChanged: ((Bool) -> Void)?
    private let request: SecureConnectionRequest?
    private let client = SecureConnectionClient()
    private var task: Task<Void, Never>?

    init(request: SecureConnectionRequest?) { self.request = request }
    var canSave: Bool {
        guard let details, !saving, !unavailable else { return false }
        if details.isPermissions { return true }
        return SecureConnectionRequest.validKey(key)
            && (access != .all || SecureConnectionDetails.validOrigin(origin.trimmingCharacters(in: .whitespacesAndNewlines)))
    }
    var permissionOnly: Bool { details?.isPermissions == true }

    func load() async {
        guard let request else { loading = false; unavailable = true; error = SecureConnectionFailure.unavailable.localizedDescription; return }
        loading = true
        error = nil
        do {
            let loaded = try await client.details(for: request)
            details = loaded
            access = loaded.connection.apiAccess
            origin = loaded.connection.origin ?? ""
        }
        catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
            unavailable = (error as? SecureConnectionFailure) == .unavailable
        }
        loading = false
    }

    func save() {
        guard canSave, let request else { return }
        saving = true
        savingChanged?(true)
        error = nil
        let value = key
        let permissionOnly = permissionOnly
        let selectedAccess = access
        let selectedOrigin = origin.trimmingCharacters(in: .whitespacesAndNewlines)
        clearKey()
        task = Task { [weak self, client] in
            do {
                if permissionOnly { try await client.approve(for: request) }
                else { try await client.save(value, for: request, access: selectedAccess, origin: selectedOrigin) }
                guard !Task.isCancelled, let self else { return }
                saved = true
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                // Only the reference is published, never a key or a request body.
                NotificationCenter.default.post(name: RipulSecureConnection.didSave, object: request.connectionID)
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.error = error.localizedDescription
                unavailable = (error as? SecureConnectionFailure) == .unavailable
                    || (error as? SecureConnectionFailure) == .saveUnconfirmed
            }
            self?.saving = false
            self?.savingChanged?(false)
            self?.task = nil
        }
    }

    func clearKey() { key = "" }
    func cancel() { clearKey(); task?.cancel(); task = nil; client.cancel() }
}

private struct SecureConnectionSheet: View {
    @ObservedObject var model: SecureConnectionModel
    let close: () -> Void
    @FocusState private var keyFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if model.saved { confirmation }
                    else if model.loading {
                        ProgressView("Checking connection…").frame(maxWidth: .infinity).padding(.top, 70)
                    } else if let details = model.details { form(details) }
                    else { unavailable }
                }
                .padding(24)
                .frame(maxWidth: 580)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color.ripul(.canvas))
            .navigationTitle(model.permissionOnly ? "API access" : "Private credential")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(model.saved ? "Done" : "Cancel", action: close).disabled(model.saving)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if model.details != nil {
                    VStack(spacing: 12) {
                        if !model.saved && !model.unavailable {
                            Text(model.access == .stored ? "Your key will be stored without allowing API calls." : "Saving approves the API access shown above.")
                                .font(.ripul(.caption)).foregroundStyle(.ripul(.textSecondary))
                        }
                        Button {
                            keyFocused = false
                            if model.saved || model.unavailable { close() } else { model.save() }
                        } label: {
                            HStack(spacing: 10) {
                                if model.saving { ProgressView().tint(.ripul(.onAccent)) }
                                Text(model.saved || model.unavailable ? "Return to chat" : model.saving ? "Saving securely…" : model.permissionOnly ? "Approve API access" : "Save credential")
                                    .font(.ripul(.headline))
                            }
                            .frame(maxWidth: .infinity).padding(.vertical, 10)
                        }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(!model.saved && !model.unavailable && !model.canSave)
                        .uiKitIdentifier("SecureConnection.save")
                    }
                    .padding(.horizontal, 24).padding(.top, 14).padding(.bottom, 12)
                    .background(.bar)
                }
            }
        }
        .dismissesKeyboardOnTapAway()
        .ripulAIContextExcluded()
        .privacySensitive()
        .task { await model.load() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            keyFocused = false
            model.clearKey()
        }
        .onDisappear { model.clearKey() }
    }

    private func form(_ details: SecureConnectionDetails) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: "lock.shield.fill")
                    .font(.ripulIcon(size: 30, weight: .medium)).foregroundStyle(.ripul(.accent))
                    .frame(width: 64, height: 64).background(.ripul(.accent).opacity(0.1), in: RoundedRectangle(cornerRadius: 20))
                Text(details.connection.name).font(.ripul(.title2, weight: .semibold))
                HStack {
                    Text(details.siteName).foregroundStyle(.ripul(.textSecondary))
                    Text(details.connection.environment == "test" ? "Test" : "Live")
                        .font(.ripul(.caption, weight: .semibold)).padding(.horizontal, 9).padding(.vertical, 4)
                        .background(.ripul(.textQuaternary), in: Capsule())
                }.font(.ripul(.subheadline))
                Text(details.isPermissions ? "Change what this saved credential can do. You don’t need to enter the key again." : "Your key is encrypted and kept out of this conversation.")
                    .font(.ripul(.subheadline)).foregroundStyle(.ripul(.textSecondary))
            }
            if !model.unavailable && !details.isPermissions {
                VStack(alignment: .leading, spacing: 10) {
                    Text(details.connection.configured ? "Replacement API key" : "API key").font(.ripul(.subheadline, weight: .semibold))
                    SecureField("Paste your API key", text: $model.key)
                        .font(.ripul(.body, family: .code))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .keyboardType(.asciiCapable).textContentType(.password)
                        .focused($keyFocused).submitLabel(.done)
                        .onSubmit { keyFocused = false }
                        .disabled(model.saving)
                        .padding(18)
                        .background(.ripul(.surface), in: RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.ripul(keyFocused ? .accent : .separator), lineWidth: 1))
                        .uiKitIdentifier("SecureConnection.key")
                        .ripulAIContextExcluded()
                    Text("Only this connection can use the saved key.")
                        .font(.ripul(.caption)).foregroundStyle(.ripul(.textSecondary))
                    if !model.key.isEmpty && !SecureConnectionRequest.validKey(model.key) {
                        Text(SecureConnectionFailure.invalidKey.localizedDescription).font(.ripul(.caption)).foregroundStyle(.ripul(.textSecondary))
                    }
                }
            }
            accessReview(details)
            if let error = model.error { Text(error).font(.ripul(.subheadline)).foregroundStyle(.ripul(.danger)) }
        }
    }

    private func accessReview(_ details: SecureConnectionDetails) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("API access", systemImage: "network").font(.ripul(.subheadline, weight: .semibold))
            if !details.isPermissions {
                Picker("API access", selection: $model.access) {
                    Text("Save only · configure later").tag(SecureConnectionAccess.stored)
                    if !details.connection.operations.isEmpty {
                        Text("Only requested operations").tag(SecureConnectionAccess.restricted)
                    }
                    Text("Allow any API call").tag(SecureConnectionAccess.all)
                }
                .pickerStyle(.menu).labelsHidden().disabled(model.saving)
                .uiKitIdentifier("SecureConnection.access")
            }
            if model.access == .stored {
                Text("No API calls allowed").font(.ripul(.body, weight: .semibold))
                Text("Save your credential now. You can approve specific calls or unrestricted access later.")
                    .font(.ripul(.subheadline)).foregroundStyle(.ripul(.textSecondary))
            } else if model.access == .all {
                if !details.isPermissions {
                    TextField("https://api.example.com or *.*", text: $model.origin)
                        .font(.ripul(.body, family: .code)).keyboardType(.URL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .padding(14).background(.ripul(.canvas), in: RoundedRectangle(cornerRadius: 12))
                        .disabled(model.saving).uiKitIdentifier("SecureConnection.origin")
                    Text("Choose a service origin, or enter *.* for any public HTTPS destination.")
                        .font(.ripul(.caption)).foregroundStyle(.ripul(.textSecondary))
                }
                Text(model.origin.trimmingCharacters(in: .whitespacesAndNewlines) == "*.*" ? "Any API call · any destination" : "Any API call · this service")
                    .font(.ripul(.body, weight: .semibold))
                if details.isPermissions { Text(details.destination).font(.ripul(.subheadline)).textSelection(.enabled) }
                Text(model.origin.trimmingCharacters(in: .whitespacesAndNewlines) == "*.*"
                     ? "The server may send this credential to any public HTTPS destination a call specifies."
                     : "All API paths and supported methods are allowed, including changes and deletions.")
                    .font(.ripul(.subheadline)).foregroundStyle(.ripul(.textSecondary))
            } else {
                Text(details.destination).font(.ripul(.body, weight: .semibold)).textSelection(.enabled)
                DisclosureGroup("Allowed requests · \(details.connection.operations.count)") {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(details.connection.operations.enumerated()), id: \.offset) { _, operation in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(operation.name).font(.ripul(.subheadline, weight: .semibold))
                                Text("\(operation.method) \(operation.url)").font(.ripul(.caption, family: .code)).textSelection(.enabled)
                                Text("Inputs: \(operation.inputFields.isEmpty ? "none" : operation.inputFields.joined(separator: ", "))")
                                Text("Returns: \(operation.outputFields.isEmpty ? "status only" : operation.outputFields.joined(separator: ", "))")
                            }.font(.ripul(.caption)).foregroundStyle(.ripul(.textSecondary)).padding(.top, 6)
                        }
                    }
                }.font(.ripul(.subheadline))
            }
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .background(.ripul(.surface), in: RoundedRectangle(cornerRadius: 18))
    }

    private var confirmation: some View {
        VStack(spacing: 18) {
            Image(systemName: "checkmark.circle.fill").font(.ripulIcon(size: 64)).foregroundStyle(.ripul(.success))
            Text(model.permissionOnly ? "API access updated" : "Credential saved").font(.ripul(.title, weight: .semibold))
            Text(model.access == .stored ? "Your credential is stored. Configure API access whenever you’re ready." : "\(model.details?.connection.name ?? "Your connection") is ready to use with the access you approved.")
                .font(.ripul(.body)).foregroundStyle(.ripul(.textSecondary))
            Text("Your key stays private. The agent can check that it’s saved.")
                .font(.ripul(.subheadline)).foregroundStyle(.ripul(.textSecondary))
        }
        .multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(.vertical, 60)
        .uiKitIdentifier("SecureConnection.connected")
    }

    private var unavailable: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock.circle").font(.ripulIcon(size: 48)).foregroundStyle(.ripul(.textSecondary))
            Text("Connection unavailable").font(.ripul(.title2, weight: .semibold))
            Text(model.error ?? SecureConnectionFailure.unavailable.localizedDescription).foregroundStyle(.ripul(.textSecondary))
            if !model.unavailable { Button("Try again") { Task { await model.load() } }.buttonStyle(.bordered) }
        }.multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(.top, 50)
    }
}
#endif
