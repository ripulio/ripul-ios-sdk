import SwiftUI

struct DomainZonesView: View {
    @ObservedObject var model: SiteDomainsModel
    @State private var adding = false
    @State private var name = ""
    var body: some View {
        List {
            if let error = model.error { Text(error).foregroundStyle(.ripul(.danger)) }
            Section {
                Button { name = ""; adding = true } label: { Label("Add a domain you own", systemImage: "plus") }
                ForEach(model.overview?.zones ?? []) { zone in
                    NavigationLink { DomainZoneDetail(model: model, zoneId: zone.id) } label: {
                        VStack(alignment: .leading) {
                            Text(zone.name)
                            Text(zone.status == "active" ? "Active" : "Nameservers pending").font(.ripul(.caption)).foregroundStyle(.ripul(.textSecondary))
                        }
                    }
                }
            }
        }
        .navigationTitle("Manage domains")
        .disabled(model.busy)
        .ripulSheet(isPresented: $adding) {
            NavigationStack {
                Form {
                    if let error = model.error { Text(error).foregroundStyle(.ripul(.danger)) }
                    Section {
                        TextField("example.com", text: $name).autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never).keyboardType(.URL)
                            #endif
                    } header: { Text("Domain") } footer: { Text("Keep your current registrar. After adding the domain, review its DNS records before changing its nameservers.") }
                    Button(model.busy ? "Adding…" : "Add domain") {
                        Task { await model.act {
                            try await model.client.perform("/zones", body: ["name":.string(name.trimmingCharacters(in:.whitespacesAndNewlines))])
                            try await model.refresh(); adding = false
                        } }
                    }.disabled(name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                }
                .navigationTitle("Add domain")
                .disabled(model.busy)
                .dismissesKeyboardOnTapAway()
                .toolbar { ToolbarItem(placement:.cancellationAction) { Button("Cancel") { adding = false }.disabled(model.busy) } }
            }
        }
    }
}

private struct DomainZoneDetail: View {
    @ObservedObject var model: SiteDomainsModel
    let zoneId: String
    @State private var review: DomainZoneReview?
    @State private var selected: Set<String> = []
    @State private var notice: String?
    private var path: String { "/zones/\(SiteDomainsClient.encode(zoneId))" }
    private func load() async throws { review = try await model.client.request(path); selected = [] }
    var body: some View {
        List {
            if let error = model.error { Text(error).foregroundStyle(.ripul(.danger)) }
            if let notice { Text(notice).font(.ripul(.footnote)) }
            if let review {
                if review.zone.status != "active" {
                    Section {
                        Text("Scan and review the existing DNS records, including email. A scan may miss records; compare with your current provider before changing nameservers.")
                        Button("Scan existing DNS") { Task { await model.act {
                            try await model.client.perform(path + "/scan")
                            notice = "Scan started. Refresh records in a moment."
                        } } }
                        Button("Refresh records") { Task { await model.act { try await load() } } }
                        ForEach(review.discovered) { record in
                            Toggle(isOn: Binding(get: { selected.contains(record.id) }, set: { if $0 { selected.insert(record.id) } else { selected.remove(record.id) } })) { dnsRow(record) }
                        }
                        if !review.discovered.isEmpty {
                            Button("Import selected records") { Task { await model.act {
                                self.review = try await model.client.request(path + "/review", method:"POST", body:["acceptIds":.array(selected.sorted().map(CmsJSON.string))])
                                selected = []
                            } } }.disabled(selected.isEmpty)
                        }
                    } header: { Text("Review DNS") }
                    Section {
                        Text("Once your DNS records are complete, replace the nameservers at your registrar with:")
                        ForEach(review.zone.nameservers, id:\.self) { Text($0).font(.ripul(.callout, family: .code)).textSelection(.enabled) }
                        Text("If DNSSEC is enabled at your registrar, turn it off before changing nameservers. Re-enable it in Cloudflare after activation.").font(.ripul(.footnote))
                        Button("Check activation") { Task { await model.act {
                            self.review = try await model.client.request(path + "/refresh", method:"POST", body:[:])
                            try await model.refresh()
                        } } }
                    } header: { Text("Nameservers") }
                }
                Section { ForEach(review.records) { dnsRow($0) } } header: { Text("DNS records in Cloudflare") }
                if let url = URL(string:"https://dash.cloudflare.com/48994301be053cfc75d066dfaed15e35/\(review.zone.name)/dns/records") {
                    Section { Link("Open DNS in Cloudflare", destination:url) }
                }
            } else if model.error == nil { ProgressView("Loading domain…") }
        }
        .navigationTitle(review?.zone.name ?? "Domain")
        .disabled(model.busy)
        .task { await model.act { try await load() } }
        .refreshable { await model.act { try await load() } }
    }
    private func dnsRow(_ record: DomainDNSRecord) -> some View {
        VStack(alignment:.leading,spacing:4) {
            Text("\(record.type) · \(record.name)").font(.ripul(.subheadline))
            Text(record.content).font(.ripul(.caption)).foregroundStyle(.ripul(.textSecondary)).textSelection(.enabled)
            if let priority = record.priority { Text("Priority \(priority)").font(.ripul(.caption)) }
        }
    }
}
