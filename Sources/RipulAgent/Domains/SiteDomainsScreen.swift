import SwiftUI

/// Site addresses and Cloudflare domain onboarding, shared by iPhone and Mac Catalyst.
public struct SiteDomainsScreen: View {
    @StateObject private var model: SiteDomainsModel
    @State private var editing: AddressEditorChoice?
    @State private var removing: SiteDomainAddress?
    @Environment(\.openURL) private var openURL
    private let cmsId: String?

    public init(clientConfig: CmsClientConfig, cmsId: String? = nil) {
        _model = StateObject(wrappedValue: SiteDomainsModel(config: clientConfig))
        self.cmsId = cmsId
    }
    private struct AddressEditorChoice: Identifiable {
        let address: SiteDomainAddress?
        var id: String { address?.hostname ?? "new" }
    }
    public var body: some View {
        List {
            if let error = model.error { Section { Text(error).foregroundStyle(.ripul(.danger)) } }
            if let data = model.overview {
                if !data.configured || data.connectionError != nil { connectionSection(data) }
                Section {
                    Button { editing = AddressEditorChoice(address: nil) } label: {
                        Label("Connect address", systemImage: "plus")
                    }
                    .disabled(!data.configured || data.connectionError != nil)
                    .accessibilityIdentifier("Domains.connectAddress")
                    ForEach(data.addresses.filter { cmsId == nil || $0.cmsId == cmsId }) { address in
                        addressRow(address, data: data)
                    }
                } header: { Text("Site addresses") }
                Section {
                    NavigationLink {
                        DomainZonesView(model: model)
                    } label: { Label("Manage domains", systemImage: "globe") }
                    .disabled(!data.configured)
                } footer: { Text("Connect addresses on ripul.io or add another domain you own.") }
            } else if model.error == nil { ProgressView("Loading domains…") }
        }
        .navigationTitle("Domains")
        .disabled(model.busy)
        .refreshable { await model.act { try await model.refresh() } }
        .toolbar { ToolbarItem(placement: .primaryAction) {
            Button { Task { await model.act { try await model.refresh() } } } label: { Image(systemName: "arrow.clockwise") }
                .accessibilityLabel("Refresh domains")
        } }
        .task { await model.act { try await model.refresh() } }
        .onReceive(NotificationCenter.default.publisher(for: RipulSecureConnection.didSave)) { _ in
            Task { await model.act { try await model.refresh() } }
        }
        .ripulSheet(item: $editing) { choice in
            NavigationStack { SiteAddressEditor(model: model, address: choice.address, initialCmsId: cmsId) }
        }
        .confirmationDialog("Disconnect \(removing?.hostname ?? "address")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            if let address = removing {
                Button("Disconnect", role: .destructive) {
                    Task { await model.act {
                        let suffix = address.siteKeyId.map { "?siteKeyId=\(SiteDomainsClient.encode($0))" } ?? ""
                        try await model.client.perform("/addresses/\(SiteDomainsClient.encode(address.hostname))\(suffix)", method: "DELETE")
                        try await model.refresh()
                    } }
                }
            }
        } message: { Text("This removes its site connection and Cloudflare hosting address. The site's other addresses remain available.") }
    }
    private func connectionSection(_ data: SiteDomainsOverview) -> some View {
        Section {
            if let error = data.connectionError { Text(error).foregroundStyle(.ripul(.danger)) }
            Text("Create a Cloudflare API token for the Ripul account with Zone Edit, DNS Edit and Cloudflare Pages Edit permissions. Include all zones to add new domains.")
                .font(.ripul(.footnote))
            Link("Create API token", destination: URL(string: "https://dash.cloudflare.com/profile/api-tokens")!)
            Button("Enter token privately") {
                Task { await model.act {
                    struct Capture: Decodable { let captureUrl: URL }
                    let result: Capture = try await model.client.request("/credential", method: "POST", body: [:])
                    if !RipulSecureConnection.open(result.captureUrl) { openURL(result.captureUrl) }
                } }
            }
        } header: { Text("Connect Cloudflare") } footer: { Text("The token is saved through Ripul's private entry form. It is never sent to the chat.") }
    }
    private func addressRow(_ address: SiteDomainAddress, data: SiteDomainsOverview) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(address.hostname).font(.ripul(.headline)).textSelection(.enabled)
                Spacer()
                Text(!data.configured && address.status == "pending" ? "Not checked" : address.statusTitle).font(.ripul(.caption)).foregroundStyle(address.status == "live" ? Color.ripul(.success) : Color.ripul(.textSecondary))
            }
            Text(data.sites.first(where: { $0.id == address.cmsId })?.name ?? (address.protected ? "Ripul platform" : "No site connected"))
                .font(.ripul(.subheadline)).foregroundStyle(.ripul(.textSecondary))
            if let message = address.message { Text(message).font(.ripul(.footnote)).foregroundStyle(.ripul(.textSecondary)) }
            HStack {
                if address.status == "live", let url = URL(string: "https://\(address.hostname)") { Link("Open site", destination: url) }
                if !address.protected {
                    Button(address.status == "live" ? "Change site" : "Connect / retry") { editing = AddressEditorChoice(address: address) }
                        .disabled(!data.configured || data.connectionError != nil)
                    Spacer()
                    if (address.siteKeyId != nil || address.managed) && address.status != "disconnected" {
                        Button("Disconnect", role: .destructive) { removing = address }.disabled(!data.configured)
                    }
                }
            }.font(.ripul(.subheadline)).buttonStyle(.borderless)
        }.padding(.vertical, 4)
    }
}

private struct SiteAddressEditor: View {
    @ObservedObject var model: SiteDomainsModel
    let address: SiteDomainAddress?
    let initialCmsId: String?
    @State private var zone = ""
    @State private var label = ""
    @State private var site = ""
    @State private var key = ""
    @Environment(\.dismiss) private var dismiss
    private var keys: [DomainSiteChoice.Key] { model.overview?.sites.first { $0.id == site }?.keys ?? [] }
    private var hostname: String { address?.hostname ?? (label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? zone : "\(label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()).\(zone)") }
    var body: some View {
        Form {
            if let error = model.error { Section { Text(error).foregroundStyle(.ripul(.danger)) } }
            Section {
                if address != nil { Text(hostname).textSelection(.enabled) }
                else {
                    Picker("Domain", selection: $zone) {
                        ForEach(model.overview?.zones.filter { $0.status == "active" } ?? []) { Text($0.name).tag($0.name) }
                    }
                    TextField("Subdomain, e.g. bookings", text: $label)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never).keyboardType(.URL)
                        #endif
                    Text(hostname).font(.ripul(.footnote)).foregroundStyle(.ripul(.textSecondary))
                }
            } header: { Text("Address") } footer: { if address == nil { Text("Leave the subdomain blank to use the domain itself.") } }
            Section {
                Picker("Site", selection: $site) { ForEach(model.overview?.sites ?? []) { Text($0.name).tag($0.id) } }
                if keys.count > 1 {
                    Picker("Configuration", selection: $key) {
                        Text("Choose configuration").tag("")
                        ForEach(keys) { Text($0.name).tag($0.id) }
                    }
                }
            } footer: { if keys.count > 1 { Text("The configuration selects the site's sign-in and member settings.") } }
            if let old = address?.cmsId, old != site { Section { Text("Visitors to this address will open the newly selected site after you connect it.") } }
            Section {
                Button(model.busy ? "Connecting…" : "Connect") {
                    Task { await model.act {
                        var body: [String:CmsJSON] = ["hostname":.string(hostname), "cmsId":.string(site), "previousSiteKeyId":address?.siteKeyId.map(CmsJSON.string) ?? .null]
                        if !key.isEmpty { body["siteKeyId"] = .string(key) }
                        try await model.client.perform("/addresses", body: body)
                        try await model.refresh()
                        dismiss()
                    } }
                }.disabled(site.isEmpty || hostname.isEmpty || (keys.count > 1 && key.isEmpty))
            }
        }
        .disabled(model.busy)
        .dismissesKeyboardOnTapAway()
        .navigationTitle("Connect address")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(model.busy) } }
        .onAppear {
            model.error = nil
            zone = model.overview?.zones.first { $0.name == "ripul.io" }?.name ?? model.overview?.zones.first { $0.status == "active" }?.name ?? ""
            site = address?.cmsId ?? initialCmsId ?? model.overview?.sites.first?.id ?? ""
            key = address?.siteKeyId ?? (keys.count == 1 ? keys[0].id : "")
        }
        .onChange(of: site) { _, _ in key = keys.count == 1 ? keys[0].id : (keys.contains { $0.id == address?.siteKeyId } ? address?.siteKeyId ?? "" : "") }
    }
}
