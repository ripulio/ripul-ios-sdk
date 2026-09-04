#if os(iOS)
import SwiftUI
import UIKit

// ---------------------------------------------------------------------------
// Native ROW BILLING management — the Solution-management surface for the
// CMS Stripe row-billing feature (docs: chrome-extension/docs/plans/
// cms-stripe-row-billing.md). Native peer of the web designer's Billing
// panel, rebuilt with platform controls per the native-first doctrine:
// List + Form + Picker, not a re-skin of the web layout.
//
// Scope matches the web surface: Connect account state + onboarding, rule
// list, rule editor (subject bindings, cardinality-many relationship,
// aggregate, metered Price). All server-validated; refusals show verbatim.
// ---------------------------------------------------------------------------

/// Cross-layer handoff for `ripul://billing` — the host app flips the latch
/// and posts the notification; SolutionManagementSection consumes whichever
/// arrives usable (notification when mounted, latch at first appear).
public enum RipulBillingDeepLink {
    public static let notification = Notification.Name("ripulOpenBillingScreen")
    /// Consumed at section appear when the section wasn't mounted in time
    /// to hear the notification.
    public static var pending = false

    public static func open() {
        pending = true
        NotificationCenter.default.post(name: notification, object: nil)
    }
}

/// What the list screen shows when a call fails: a legible summary line,
/// plus the raw server payload (a proxy's HTML 502 page, an unexpected
/// body) behind an "Advanced" disclosure the tenant can copy for support.
struct RipulBillingSurfaceError {
    let summary: String
    let detail: String?
    /// URLs mentioned in the summary (e.g. Stripe's "sign up at …") —
    /// rendered as tappable links under the message.
    let links: [URL]

    init(_ error: Error) {
        summary = error.localizedDescription
        detail = (error as? RipulSolutionContextsError)?.serverDetail
        links = Self.urls(in: summary)
    }

    private static func urls(in text: String) -> [URL] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return detector.matches(in: text, options: [], range: range).compactMap { $0.url }
    }
}

@MainActor
final class RipulBillingModel: ObservableObject {
    @Published private(set) var siteKeys: [RipulSiteKeySummary] = []
    @Published var selectedSiteKeyId: String? {
        didSet { if oldValue != selectedSiteKeyId { Task { await loadSelected() } } }
    }
    @Published private(set) var account: RipulBillingAccount?
    @Published private(set) var platform: RipulBillingPlatformStatus?
    @Published private(set) var accountLoaded = false
    @Published var provisioning = false
    @Published var unbinding = false
    @Published private(set) var rules: [RipulBillingRule] = []
    @Published private(set) var prices: [RipulBillingPrice] = []
    @Published private(set) var cmsRefs: RipulBillingCmsRefs?
    @Published var loading = false
    @Published var surfaceError: RipulBillingSurfaceError?
    /// Warnings from the last accepted save — overlap notices the tenant
    /// should read (the server saves anyway; intent is theirs to confirm).
    @Published var lastSaveWarnings: [String] = []

    private let billingClient: RipulBillingClient
    private let siteKeysClient: RipulSiteKeysClient

    init(billingClient: RipulBillingClient, siteKeysClient: RipulSiteKeysClient) {
        self.billingClient = billingClient
        self.siteKeysClient = siteKeysClient
    }

    var selectedSiteKey: RipulSiteKeySummary? {
        siteKeys.first { $0.id == selectedSiteKeyId }
    }

    /// Billing binds CMS queries, so only keys linked to a CMS qualify.
    func load() async {
        loading = true
        surfaceError = nil
        do {
            let keys = try await siteKeysClient.list().filter { $0.cmsDefinitionId != nil }
            siteKeys = keys
            if selectedSiteKeyId == nil || !keys.contains(where: { $0.id == selectedSiteKeyId }) {
                selectedSiteKeyId = keys.first?.id
            } else {
                await loadSelected()
            }
        } catch {
            surfaceError = RipulBillingSurfaceError(error)
        }
        loading = false
    }

    func loadSelected() async {
        guard let keyId = selectedSiteKeyId else { return }
        surfaceError = nil
        accountLoaded = false
        do {
            async let accountTask = billingClient.accountState(siteKeyId: keyId)
            async let rulesTask = billingClient.rules(siteKeyId: keyId)
            let state = try await accountTask
            account = state.account
            platform = state.platform
            rules = try await rulesTask
            accountLoaded = true
            if let account, account.onboardingState != "revoked" {
                // Prices are the editor's concern; their failure shouldn't
                // blank the whole screen — keep it for the editor to show.
                prices = (try? await billingClient.prices(siteKeyId: keyId)) ?? []
            } else {
                prices = []
            }
            if let cmsRef = selectedSiteKey?.cmsDefinitionId {
                cmsRefs = try? await billingClient.cmsRefs(cmsRef: cmsRef)
            } else {
                cmsRefs = nil
            }
        } catch {
            surfaceError = RipulBillingSurfaceError(error)
        }
    }

    /// OAuth — connecting an EXISTING Stripe account (optional path).
    func connectExistingUrl() async -> URL? {
        guard let keyId = selectedSiteKeyId else { return nil }
        do {
            return try await billingClient.connectAuthorizeUrl(siteKeyId: keyId)
        } catch {
            surfaceError = RipulBillingSurfaceError(error)
            return nil
        }
    }

    /// Runtime onboarding: create-or-continue via Stripe-hosted Account Links.
    func onboardingUrl() async -> URL? {
        guard let keyId = selectedSiteKeyId else { return nil }
        do {
            return try await billingClient.startOnboarding(siteKeyId: keyId)
        } catch {
            surfaceError = RipulBillingSurfaceError(error)
            return nil
        }
    }

    func provision() async {
        provisioning = true
        do {
            platform = try await billingClient.provisionPlatform()
        } catch {
            surfaceError = RipulBillingSurfaceError(error)
        }
        provisioning = false
    }

    /// "Start over": unbind the account so the create/connect choice comes
    /// back. Removes only Ripul's binding — nothing in Stripe is cancelled.
    func unbind() async {
        guard let keyId = selectedSiteKeyId else { return }
        unbinding = true
        do {
            try await billingClient.unbindAccount(siteKeyId: keyId)
            await loadSelected()
        } catch {
            surfaceError = RipulBillingSurfaceError(error)
        }
        unbinding = false
    }

    /// Throws so the editor keeps its own error surface; warnings from an
    /// accepted save land on the list screen where they stay visible.
    func save(ruleId: String?, input: RipulBillingRuleInput) async throws {
        guard let keyId = selectedSiteKeyId else { return }
        let result = try await billingClient.saveRule(siteKeyId: keyId, ruleId: ruleId, input: input)
        lastSaveWarnings = result.warnings
        await loadSelected()
    }

    func delete(rule: RipulBillingRule) async {
        do {
            try await billingClient.deleteRule(id: rule.id, siteKeyId: rule.siteKeyId)
            await loadSelected()
        } catch {
            surfaceError = RipulBillingSurfaceError(error)
        }
    }

    /// "Create plan": Meter + Product + metered Price on the TENANT's account,
    /// so nobody authors a first plan in the Stripe dashboard. No cut. Returns
    /// the new Price id (already in `prices` after the reload).
    func createPlan(name: String, unitLabel: String, unitAmount: Int, currency: String, interval: String) async -> String? {
        guard let keyId = selectedSiteKeyId else { return nil }
        do {
            let priceId = try await billingClient.createPlan(
                siteKeyId: keyId, name: name, unitLabel: unitLabel,
                unitAmount: unitAmount, currency: currency, interval: interval
            )
            await loadSelected()
            return priceId
        } catch {
            surfaceError = RipulBillingSurfaceError(error)
            return nil
        }
    }

    func priceLabel(for id: String) -> String {
        prices.first { $0.id == id }?.displayLabel ?? id
    }
}

@available(iOS 16.0, *)
public struct RipulBillingScreen: View {
    @StateObject private var model: RipulBillingModel
    @Environment(\.openURL) private var openURL

    @State private var editing: EditorTarget?
    @State private var deleteTarget: RipulBillingRule?
    @State private var confirmingUnbind = false
    @State private var creatingPlan = false

    /// `Identifiable` wrapper so "new" and "edit rule X" share one sheet.
    private struct EditorTarget: Identifiable {
        let rule: RipulBillingRule?
        var id: String { rule?.id ?? "new" }
    }

    init(billingClient: RipulBillingClient, siteKeysClient: RipulSiteKeysClient) {
        _model = StateObject(wrappedValue: RipulBillingModel(
            billingClient: billingClient,
            siteKeysClient: siteKeysClient
        ))
    }

    public var body: some View {
        List {
            if let error = model.surfaceError {
                Section {
                    Label(error.summary, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .uiKitIdentifier("RipulBilling.error.summary")
                    ForEach(error.links, id: \.absoluteString) { link in
                        Link(destination: link) {
                            Label((link.host ?? "") + link.path, systemImage: "arrow.up.forward.app")
                                .font(.footnote)
                        }
                        .uiKitIdentifier("RipulBilling.error.link")
                    }
                    if let detail = error.detail {
                        DisclosureGroup {
                            Text(detail)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(16)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                            Button {
                                UIPasteboard.general.string = "\(error.summary)\n\n\(detail)"
                            } label: {
                                Label("Copy error details", systemImage: "doc.on.doc")
                                    .font(.footnote)
                            }
                            .uiKitIdentifier("RipulBilling.error.copy")
                        } label: {
                            Text("Advanced")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .uiKitIdentifier("RipulBilling.error.advanced")
                    }
                }
            }

            if model.siteKeys.isEmpty && !model.loading {
                Section {
                    Text("No site key is linked to a CMS portal. Row billing binds a portal's queries, so link a key first.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                if model.siteKeys.count > 1 {
                    Section {
                        Picker("Site key", selection: $model.selectedSiteKeyId) {
                            ForEach(model.siteKeys) { key in
                                Text(key.name).tag(Optional(key.id))
                            }
                        }
                        .uiKitIdentifier("RipulBilling.siteKeyPicker")
                    }
                }

                accountSection
                rulesSection
                stripeLinksSection
            }
        }
        .uiKitIdentifier("RipulBilling.list")
        .navigationTitle("Row Billing")
        .refreshable { await model.load() }
        .task { await model.load() }
        .sheet(item: $editing) { target in
            NavigationStack {
                RipulBillingRuleEditorView(model: model, rule: target.rule)
            }
        }
        .sheet(isPresented: $creatingPlan) {
            NavigationStack {
                RipulBillingPlanSheet(model: model) {
                    creatingPlan = false
                }
            }
        }
        .confirmationDialog(
            "Delete rule \u{201C}\(deleteTarget?.name ?? "")\u{201D}?",
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete rule", role: .destructive) {
                if let rule = deleteTarget {
                    Task { await model.delete(rule: rule) }
                }
                deleteTarget = nil
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("Deleting a rule never cancels anything in Stripe — existing subscriptions keep billing until someone acts in the Stripe dashboard.")
        }
    }

    // MARK: Account

    @ViewBuilder
    private var accountSection: some View {
        Section {
            if !model.accountLoaded {
                HStack { ProgressView(); Text("Loading…").font(.footnote).foregroundStyle(.secondary) }
            } else if let platform = model.platform, !platform.secretKeyConfigured {
                Label(
                    "Row billing isn't provisioned on this platform yet. One deploy-time step remains: set BILLING_STRIPE_SECRET_KEY on the worker (wrangler secret put, from chrome-extension/packages/api). Everything else provisions itself at runtime from here.",
                    systemImage: "key.slash"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            } else if let platform = model.platform, !platform.webhookConfigured {
                Button {
                    Task { await model.provision() }
                } label: {
                    HStack {
                        Label("Finish platform setup", systemImage: "wand.and.stars")
                        Spacer()
                        if model.provisioning { ProgressView() }
                    }
                }
                .disabled(model.provisioning)
                .uiKitIdentifier("RipulBilling.provision")
            } else if model.account == nil, model.platform?.connectEnabled == false {
                Label(
                    "Stripe Connect isn't enabled on the platform account yet — a one-time signup in the Stripe dashboard. Accounts can't be created until it's done; pull to refresh here afterwards.",
                    systemImage: "point.3.connected.trianglepath.dotted"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                Link(destination: URL(string: "https://dashboard.stripe.com/connect")!) {
                    Label("Enable Connect in the Stripe dashboard", systemImage: "arrow.up.forward.app")
                }
                .uiKitIdentifier("RipulBilling.enableConnect")
            } else if let account = model.account {
                HStack(spacing: 10) {
                    Image(systemName: accountIcon(account))
                        .foregroundStyle(accountTint(account))
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(accountLabel(account))
                            .font(.subheadline.weight(.medium))
                        Text(account.stripeAccountId + (account.livemode ? "" : " · test mode"))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                if account.onboardingState == "onboarding" || account.onboardingState == "restricted" {
                    Button {
                        openOnboarding()
                    } label: {
                        Label("Continue onboarding", systemImage: "arrow.up.forward.app")
                    }
                    .uiKitIdentifier("RipulBilling.continueOnboarding")
                    if model.platform?.oauthConfigured == true {
                        Button {
                            openConnectExisting()
                        } label: {
                            Label("Connect an existing account instead", systemImage: "link")
                        }
                        .uiKitIdentifier("RipulBilling.connectExistingInstead")
                    }
                }
                startOverButton(account)
                if account.onboardingState == "revoked" {
                    Button("Reconnect Stripe") {
                        if model.platform?.oauthConfigured == true { openConnectExisting() } else { openOnboarding() }
                    }
                    .uiKitIdentifier("RipulBilling.reconnect")
                }
                if account.onboardingState == "active" && !account.payoutsEnabled {
                    Label(
                        "Charges are enabled but payouts are not — money accumulates in Stripe and never reaches the bank until payouts are enabled in the Stripe dashboard.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            } else {
                Button {
                    openOnboarding()
                } label: {
                    Label("Create Stripe account", systemImage: "plus.app")
                }
                .uiKitIdentifier("RipulBilling.create")
                if model.platform?.oauthConfigured == true {
                    Button {
                        openConnectExisting()
                    } label: {
                        Label("Connect an existing account", systemImage: "link")
                    }
                    .uiKitIdentifier("RipulBilling.connectExisting")
                }
            }
        } header: {
            Text("Stripe account")
        } footer: {
            if model.account == nil && model.accountLoaded {
                Text("Onboarding is Stripe-hosted and entirely self-serve: the account is the tenant's own — merchant of record, full dashboard; Ripul never holds funds and takes no fee. Opens in the browser; pull to refresh here afterwards.")
            }
        }
    }

    /// "Start over" — unbind so the create/connect choice comes back. The
    /// dialog states the Stripe-side consequences (none) so the tenant is
    /// never guessing what a destructive-styled button does to live billing.
    @ViewBuilder
    private func startOverButton(_ account: RipulBillingAccount) -> some View {
        Button(role: .destructive) {
            confirmingUnbind = true
        } label: {
            if model.unbinding {
                HStack { Text("Start over…"); Spacer(); ProgressView() }
            } else {
                Label("Start over with a different account", systemImage: "arrow.uturn.backward")
            }
        }
        .disabled(model.unbinding)
        .uiKitIdentifier("RipulBilling.startOver")
        .confirmationDialog(
            "Start over with a different Stripe account?",
            isPresented: $confirmingUnbind,
            titleVisibility: .visible
        ) {
            Button("Unbind \(account.stripeAccountId)", role: .destructive) {
                Task { await model.unbind() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Removes the link between this site key and the account so you can create or connect a different one. Nothing in Stripe is cancelled or deleted — the account and any subscriptions on it are untouched."
                + (account.onboardingState == "active" && !model.rules.isEmpty
                    ? " \(model.rules.count) billing rule\(model.rules.count == 1 ? "" : "s") reference Prices from this account and will need re-pointing."
                    : "")
            )
        }
    }

    private func openOnboarding() {
        Task {
            if let url = await model.onboardingUrl() { openURL(url) }
        }
    }

    private func openConnectExisting() {
        Task {
            if let url = await model.connectExistingUrl() { openURL(url) }
        }
    }

    private func accountLabel(_ account: RipulBillingAccount) -> String {
        switch account.onboardingState {
        case "active": return "Connected — charges enabled"
        case "onboarding": return "Onboarding — finish Stripe setup to enable charges"
        case "restricted": return "Restricted — charges disabled by Stripe"
        case "revoked": return "Revoked — access was removed from the Stripe dashboard"
        default: return account.onboardingState
        }
    }

    private func accountIcon(_ account: RipulBillingAccount) -> String {
        switch account.onboardingState {
        case "active": return "checkmark.seal.fill"
        case "revoked": return "xmark.seal.fill"
        default: return "clock.badge.exclamationmark"
        }
    }

    private func accountTint(_ account: RipulBillingAccount) -> AnyShapeStyle {
        switch account.onboardingState {
        case "active": return AnyShapeStyle(.green)
        case "revoked": return AnyShapeStyle(.red)
        default: return AnyShapeStyle(.orange)
        }
    }

    // MARK: Stripe dashboard links

    /// Dashboard URLs honour the platform's key mode — test-mode data lives
    /// under /test/ paths and is invisible on the live dashboard.
    private func stripeDashboardURL(_ path: String) -> URL {
        let prefix = model.platform?.mode == "test" ? "test/" : ""
        return URL(string: "https://dashboard.stripe.com/\(prefix)\(path)")
            ?? URL(string: "https://dashboard.stripe.com")!
    }

    @ViewBuilder
    private func stripeLinkRow(_ title: String, _ subtitle: String, _ icon: String, url: URL, id: String) -> some View {
        Link(destination: url) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(.tint)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "arrow.up.forward")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .uiKitIdentifier(id)
    }

    @ViewBuilder
    private var stripeLinksSection: some View {
        Section {
            stripeLinkRow(
                "Connect",
                "Platform signup and connected accounts",
                "point.3.connected.trianglepath.dotted",
                url: stripeDashboardURL("connect/accounts/overview"),
                id: "RipulBilling.links.connect"
            )
            stripeLinkRow(
                "Products & Prices",
                "Author the metered Prices rules bill against",
                "shippingbox",
                url: stripeDashboardURL("products"),
                id: "RipulBilling.links.products"
            )
            stripeLinkRow(
                "Billing meters",
                "Usage meters behind metered Prices",
                "gauge.with.needle",
                url: stripeDashboardURL("meters"),
                id: "RipulBilling.links.meters"
            )
            stripeLinkRow(
                "Webhooks",
                "The platform's self-registered Connect endpoint",
                "arrow.triangle.branch",
                url: stripeDashboardURL("webhooks"),
                id: "RipulBilling.links.webhooks"
            )
        } header: {
            Text("Stripe dashboard")
        } footer: {
            Text("Opens the platform's Stripe dashboard in the browser\(model.platform?.mode == "test" ? " (test mode)" : "").")
        }
    }

    // MARK: Rules

    @ViewBuilder
    private var rulesSection: some View {
        Section {
            if !model.lastSaveWarnings.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.lastSaveWarnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            ForEach(model.rules) { rule in
                Button { editing = EditorTarget(rule: rule) } label: { ruleRow(rule) }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        Button("Delete", role: .destructive) { deleteTarget = rule }
                    }
            }
            if model.rules.isEmpty && model.accountLoaded {
                Text("No billing rules yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Button {
                editing = EditorTarget(rule: nil)
            } label: {
                Label("New rule", systemImage: "plus")
            }
            .disabled(model.account == nil || model.account?.onboardingState == "revoked")
            .uiKitIdentifier("RipulBilling.newRule")
            Button {
                creatingPlan = true
            } label: {
                Label("Create plan (no Stripe dashboard needed)", systemImage: "tag")
            }
            .disabled(model.account?.onboardingState != "active")
            .uiKitIdentifier("RipulBilling.createPlan")
        } header: {
            Text("Billing rules")
        } footer: {
            Text("Billing is in arrears: Checkout captures the card but charges nothing — each period's invoice bills that period's peak quantity. Revenue and failed payments live in the tenant's own Stripe dashboard.")
        }
    }

    @ViewBuilder
    private func ruleRow(_ rule: RipulBillingRule) -> some View {
        HStack(spacing: 10) {
            Image(systemName: rule.dryRun ? "eye" : "bolt.fill")
                .foregroundStyle(rule.status == "active" && !rule.dryRun ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.name)
                    .font(.subheadline.weight(.semibold))
                Text("\(rule.status)\(rule.dryRun ? " · dry run" : "") · \(rule.subjectQuery) · \(model.priceLabel(for: rule.stripePriceId))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Rule editor

@available(iOS 16.0, *)
struct RipulBillingRuleEditorView: View {
    @ObservedObject var model: RipulBillingModel
    let rule: RipulBillingRule?

    @Environment(\.dismiss) private var dismiss

    @State private var input = RipulBillingRuleInput()
    @State private var didLoad = false
    @State private var saving = false
    @State private var saveErrors: [String] = []
    @State private var confirmOverlap = false

    var body: some View {
        Form {
            if !saveErrors.isEmpty {
                Section {
                    ForEach(saveErrors, id: \.self) { error in
                        Label(error, systemImage: "xmark.octagon")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                TextField("Name", text: $input.name)
                    .uiKitIdentifier("RipulBilling.editor.name")
                Picker("Status", selection: $input.status) {
                    Text("Draft").tag("draft")
                    Text("Active").tag("active")
                }
                Toggle("Dry run", isOn: $input.dryRun)
                    .uiKitIdentifier("RipulBilling.editor.dryRun")
            } footer: {
                Text("Dry run is shadow mode: the billing engine computes and logs every push it would make, and pushes nothing to Stripe. The natural first step for a new rule.")
            }

            Section {
                Picker("Subject query", selection: $input.subjectQuery) {
                    Text("None").tag("")
                    ForEach(model.cmsRefs?.queries ?? []) { query in
                        Text(query.name).tag(query.id)
                    }
                }
                TextField("Primary key column", text: $input.subjectPkColumn)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                TextField("Billing email column", text: $input.contactEmailColumn)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                TextField("Display name column (optional)", text: $input.displayNameColumn)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            } header: {
                Text("Subject — which rows get billed")
            } footer: {
                Text("Each row matching the subject query becomes one Stripe subscriber. The primary key must stay stable for years — it links the row to its subscription.")
            }

            Section {
                Picker("Relationship", selection: $input.quantityRelationshipId) {
                    Text("None").tag("")
                    ForEach(model.cmsRefs?.relationships ?? []) { rel in
                        Text("\(rel.name) (\(rel.fromQuery) \u{2192} \(rel.toQuery))").tag(rel.id)
                    }
                }
                Picker("Aggregation", selection: $input.quantityAgg) {
                    Text("Count").tag("count")
                    Text("Sum").tag("sum")
                    Text("Average").tag("avg")
                    Text("Min").tag("min")
                    Text("Max").tag("max")
                }
                if input.quantityAgg != "count" {
                    TextField("Value column", text: $input.quantityValueColumn)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
            } header: {
                Text("Quantity — what each row pays for")
            } footer: {
                if (model.cmsRefs?.relationships ?? []).isEmpty {
                    Text("No \u{201C}Many rows (server rollup)\u{201D} relationships exist on the linked portal — create one in the designer first.")
                } else {
                    Text("The related set is aggregated per subject row, server-side, one grouped query per cycle.")
                }
            }

            Section {
                if model.prices.isEmpty {
                    Text("No recurring Prices on the connected account yet. Create a METERED Price backed by a Billing Meter with \u{201C}Last\u{201D} aggregation in the Stripe dashboard, then pull to refresh.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(model.prices) { price in
                    Button {
                        guard price.isMetered else { return }
                        input.stripePriceId = price.id
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(price.displayLabel)
                                    .foregroundStyle(price.isMetered ? .primary : .secondary)
                                if !price.isMetered {
                                    Text("Licensed — rules need a metered Price")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else if let event = price.meterEventName {
                                    Text("Meter event: \(event)")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if input.stripePriceId == price.id {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!price.isMetered)
                }
            } header: {
                Text("Price — authored in the Stripe dashboard")
            } footer: {
                Text("The period's peak bills, in arrears — one invoice per period, no mid-period charges. The meter's event name is read from the Price at push time.")
            }
        }
        .uiKitIdentifier("RipulBilling.editor")
        .navigationTitle(rule == nil ? "New rule" : "Edit rule")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                if saving {
                    ProgressView()
                } else {
                    Button("Save") { saveTapped() }
                        .uiKitIdentifier("RipulBilling.editor.save")
                }
            }
        }
        .onAppear {
            guard !didLoad else { return }
            didLoad = true
            if let rule { input = RipulBillingRuleInput(rule: rule) }
        }
        .confirmationDialog(
            "Same subject, different Price",
            isPresented: $confirmOverlap,
            titleVisibility: .visible
        ) {
            Button("Save anyway") { Task { await save() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Another rule already bills this subject query with a different Price. Rows matching both get two subscriptions and two invoices — deliberate for separate products (e.g. seats + storage).")
        }
    }

    private func saveTapped() {
        // The plan's overlap policy: different-Price overlap is a product,
        // not a bug — surfaced for explicit confirmation, never forbidden.
        let overlaps = model.rules.contains { other in
            other.id != rule?.id
                && other.subjectQuery == input.subjectQuery
                && other.stripePriceId != input.stripePriceId
        }
        if overlaps {
            confirmOverlap = true
        } else {
            Task { await save() }
        }
    }

    private func save() async {
        saving = true
        saveErrors = []
        do {
            try await model.save(ruleId: rule?.id, input: input)
            dismiss()
        } catch let validation as RipulBillingValidationError {
            saveErrors = validation.errors
        } catch {
            saveErrors = [error.localizedDescription]
        }
        saving = false
    }
}


// MARK: - Create plan sheet

/// A per-unit metered plan created ON THE TENANT's connected account (Meter +
/// Product + metered Price) — the friction remover. The objects are theirs, in
/// their dashboard; Ripul takes no cut. Afterwards the new Price is in the rule
/// editor's picker.
@available(iOS 16.0, *)
struct RipulBillingPlanSheet: View {
    @ObservedObject var model: RipulBillingModel
    let onDone: () -> Void

    @State private var name = ""
    @State private var unitLabel = "Active employees"
    @State private var priceText = ""
    @State private var currency = "gbp"
    @State private var interval = "month"
    @State private var saving = false
    @State private var createdPriceId: String?
    @State private var localError: String?

    private var unitAmount: Int? {
        guard let major = Double(priceText.replacingOccurrences(of: ",", with: ".")), major >= 0 else { return nil }
        return Int((major * 100).rounded())
    }

    var body: some View {
        Form {
            Section {
                TextField("Plan name (on invoices)", text: $name)
                    .uiKitIdentifier("RipulBillingPlan.name")
                TextField("What is counted (e.g. Active employees)", text: $unitLabel)
                    .uiKitIdentifier("RipulBillingPlan.unitLabel")
                HStack {
                    TextField("Price per unit", text: $priceText)
                        .keyboardType(.decimalPad)
                        .uiKitIdentifier("RipulBillingPlan.price")
                    TextField("Currency", text: $currency)
                        .textInputAutocapitalization(.never)
                        .frame(width: 70)
                        .uiKitIdentifier("RipulBillingPlan.currency")
                }
                Picker("Billed", selection: $interval) {
                    Text("Monthly").tag("month")
                    Text("Yearly").tag("year")
                }
                .uiKitIdentifier("RipulBillingPlan.interval")
            } footer: {
                Text("Creates the Meter, Product and metered Price on the connected Stripe account — the account owner's objects, in their dashboard. Ripul takes no cut.")
            }
            if let localError {
                Section {
                    Label(localError, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            if let createdPriceId {
                Section {
                    Label("Plan created — pick it in a new rule.", systemImage: "checkmark.seal")
                    Text(model.priceLabel(for: createdPriceId))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Create plan")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(createdPriceId == nil ? "Cancel" : "Done") { onDone() }
            }
            ToolbarItem(placement: .confirmationAction) {
                if createdPriceId == nil {
                    Button(saving ? "Creating…" : "Create") {
                        guard let unitAmount else {
                            localError = "Enter a non-negative price per unit."
                            return
                        }
                        guard !name.trimmingCharacters(in: .whitespaces).isEmpty,
                              !unitLabel.trimmingCharacters(in: .whitespaces).isEmpty else {
                            localError = "Plan name and unit label are required."
                            return
                        }
                        saving = true
                        localError = nil
                        Task {
                            let id = await model.createPlan(
                                name: name.trimmingCharacters(in: .whitespaces),
                                unitLabel: unitLabel.trimmingCharacters(in: .whitespaces),
                                unitAmount: unitAmount,
                                currency: currency.trimmingCharacters(in: .whitespaces).lowercased(),
                                interval: interval
                            )
                            saving = false
                            if let id { createdPriceId = id } else { localError = model.surfaceError?.summary ?? "Plan creation failed" }
                        }
                    }
                    .disabled(saving)
                    .uiKitIdentifier("RipulBillingPlan.create")
                }
            }
        }
    }
}
#endif
