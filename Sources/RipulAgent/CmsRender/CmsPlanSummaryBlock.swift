import SwiftUI

/// Native twin of `planSummary` (PlanSummaryBlock.tsx + billingFormat.ts):
/// the signed-in manager's own plan — a brand hero ("Your free month ends in
/// 12 days"), the plan card (price per unit, the running estimate, what's
/// included) and the billing card (status, trial end or next charge, card on
/// file) with a way into Stripe's Billing Portal.
///
/// Semantics mirrored: GET /v1/billing/my-plan?siteKey= with the member's own
/// login (403 = only owners and managers), the hero's state order
/// (cancelling, trial with its 1-day wording, overdue, ended, active), token
/// filling where a missing value drops the line, the rows the web shows, and
/// the money/date/payment-method wording.
///
/// Presentation: cards with native label/value rows; the Stripe portal opens
/// in Safari (`openURL`), as a native app leaves for a payment site.
struct CmsPlanSummaryBlockView: View {
    let block: CmsBlock
    @EnvironmentObject var runtime: CmsRuntime
    @Environment(\.openURL) private var openURL

    private enum Load { case loading, ready(CmsJSON), forbidden, error(String) }
    @State private var load: Load = .loading
    @State private var busy: String?
    @State private var actionError: String?

    private var props: [String: CmsJSON] { block.props }
    private func text(_ key: String, _ fallback: String) -> String {
        props.string(key) ?? fallback
    }

    var body: some View {
        Group {
            switch load {
            case .loading:
                VStack(spacing: 16) {
                    RoundedRectangle(cornerRadius: runtime.theme.cardRadius).fill(runtime.theme.surfaceMuted).frame(height: 112)
                    RoundedRectangle(cornerRadius: runtime.theme.cardRadius).fill(runtime.theme.surfaceMuted).frame(height: 220)
                }
                .redacted(reason: .placeholder)
            case .forbidden:
                message("Only owners and managers can see the plan and billing.", retry: false)
            case .error(let text):
                message(text, retry: true)
            case .ready(let plan):
                ready(plan)
            }
        }
        .task(id: runtime.client.siteKeyPublishable) { await fetch() }
    }

    private func fetch() async {
        guard let siteKey = runtime.client.siteKeyPublishable else {
            load = .error("This block only works on a portal page.")
            return
        }
        load = .loading
        do {
            let encoded = siteKey.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? siteKey
            load = .ready(try await runtime.client.json("/v1/billing/my-plan?siteKey=\(encoded)"))
        } catch CmsClientError.http(403, _) {
            load = .forbidden
        } catch {
            load = .error(CmsQueryErrorText.describe(error.localizedDescription).kind == .unavailable
                          ? "Your plan can't be loaded right now. Try again in a few minutes."
                          : "Could not load your plan.")
        }
    }

    private func openPortal(_ which: String) {
        guard busy == nil, let siteKey = runtime.client.siteKeyPublishable else { return }
        busy = which
        actionError = nil
        Task {
            do {
                let res = try await runtime.client.json("/v1/billing/my-plan/portal", method: "POST",
                                                        body: ["siteKey": .string(siteKey), "returnUrl": .string(RipulDomain.demoURL)])
                guard let link = res.objectValue?.string("url"), let url = URL(string: link) else {
                    throw CmsClientError.queryFailed("Stripe did not return a link")
                }
                openURL(url)
            } catch {
                actionError = "Could not open billing."
            }
            busy = nil
        }
    }

    private var cardShape: some View {
        RoundedRectangle(cornerRadius: runtime.theme.cardRadius, style: .continuous)
            .fill(runtime.theme.paper)
            .overlay(RoundedRectangle(cornerRadius: runtime.theme.cardRadius, style: .continuous).strokeBorder(runtime.theme.divider))
    }

    private func message(_ text: String, retry: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "creditcard").foregroundColor(runtime.theme.primary)
            Text(text).font(.system(size: 15, weight: .semibold)).frame(maxWidth: .infinity, alignment: .leading)
            if retry { Button("Try again") { Task { await fetch() } }.buttonStyle(.borderless) }
        }
        .padding(16)
        .background(cardShape)
    }

    // MARK: - Ready

    private func ready(_ json: CmsJSON) -> some View {
        let plan = json.objectValue ?? [:]
        guard let p = plan.object("plan") else {
            return AnyView(message(plan.string("reason") == "not_connected"
                                   ? "Billing is not set up on this portal yet."
                                   : text("emptyText", "There's no plan on your account yet."), retry: false))
        }
        let status = plan.string("status") ?? ""
        let trialing = status == "trialing"
        let cancelling = plan.bool("cancelAtPeriodEnd") ?? false
        let trialEnd = Self.date(plan.string("trialEnd"))
        let periodEnd = plan.string("currentPeriodEnd")
        let daysLeft = trialEnd.map { max(0, Int(ceil($0.timeIntervalSinceNow / 86_400))) }
        let estimate = plan.object("nextChargeEstimate")
        let currency = p.string("currency") ?? "gbp"
        let estimateAmount = estimate?.double("amount").map { Self.money($0, estimate?.string("currency") ?? currency) }
        let tokenDate = Self.longDate(cancelling ? periodEnd : trialing ? plan.string("trialEnd") : (estimate?.string("date") ?? periodEnd))
        let tokens: [String: String?] = ["days": daysLeft.map(String.init), "date": tokenDate, "amount": estimateAmount]

        var heroTemplate: String
        if cancelling { heroTemplate = text("heroCancellingText", "Your plan ends on {date}") }
        else if trialing {
            let t = text("heroTrialText", "Your free month ends in {days} days")
            heroTemplate = daysLeft == 1 ? t.replacingOccurrences(of: "{days} days", with: "1 day") : t
        } else if status == "past_due" || status == "unpaid" { heroTemplate = "Your last payment didn't go through" }
        else if status == "canceled" || status == "incomplete_expired" { heroTemplate = "Your plan has ended" }
        else { heroTemplate = text("heroActiveText", "Your plan is active") }
        let hero = Self.fill(heroTemplate, tokens) ?? Self.fill(text("heroActiveText", "Your plan is active"), tokens) ?? "Your plan"
        let sublineTemplate = text("heroSubline", "Next charge {amount} on {date}")
        let subline = !sublineTemplate.isEmpty && !cancelling ? Self.fill(sublineTemplate, tokens) : nil

        let unit = text("unitLabel", "employee").trimmingCharacters(in: .whitespaces)
        let interval = p.string("interval") ?? ""
        let perLine = [unit.isEmpty ? "" : "per \(unit)", interval.isEmpty ? "" : "per \(interval)"].filter { !$0.isEmpty }.joined(separator: ", ")
        let unitAmount = p.double("unitAmount")
        let qty = plan.double("quantity")
        let estimateLine: String? = {
            guard let qty, let unitAmount else { return nil }
            let n = Int(qty)
            return "\(n) \(Self.plural(unit.isEmpty ? "unit" : unit, n)) · \(Self.money(unitAmount * qty, currency))\(interval.isEmpty ? "" : " a \(interval)")"
        }()
        let features: [String] = {
            guard case .array(let raw) = props["features"] ?? .null else {
                return ["Rotas, timesheets and payroll exports", "Only pay for active employees", "Cancel any time"]
            }
            return raw.compactMap { $0.objectValue?.string("text")?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }()

        var rows: [(String, String)] = [("Status", Self.statusLabel(status, cancelling))]
        if trialing && !cancelling, let end = Self.longDate(plan.string("trialEnd")) { rows.append(("Free trial ends", end)) }
        if cancelling {
            if let end = Self.longDate(periodEnd) { rows.append(("Plan ends", end)) }
        } else if let estimateAmount {
            rows.append(("Next charge", Self.longDate(estimate?.string("date")).map { "\(estimateAmount) on \($0)" } ?? estimateAmount))
        } else if status != "canceled", let renews = Self.longDate(periodEnd) {
            rows.append(("Renews", renews))
        }
        rows.append(("Payment method", Self.paymentMethod(plan.object("paymentMethod")) ?? "None on file"))
        let overdue = status == "past_due" || status == "unpaid"
        let cta = text("ctaLabel", "")
        let ctaPage = text("ctaPageSlug", "")
        let ctaURL = URL(string: text("ctaUrl", ""))

        return AnyView(VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                if let product = p.string("productName"), !product.isEmpty {
                    Text(product.uppercased()).font(.system(size: 12, weight: .bold)).tracking(1).opacity(0.85)
                }
                Text(hero).font(.system(size: 22, weight: .heavy))
                if let subline { Text(subline).font(.system(size: 15)).opacity(0.9) }
            }
            .foregroundColor(runtime.theme.primaryContrast)
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(runtime.theme.gradient, in: RoundedRectangle(cornerRadius: runtime.theme.cardRadius, style: .continuous))
            .cmsInspectorID("Cms.planSummary.hero")

            VStack(alignment: .leading, spacing: 12) {
                Text("Your plan").font(.system(size: 13, weight: .bold)).foregroundColor(runtime.theme.textSecondary)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(unitAmount.map { Self.money($0, currency) } ?? "—")
                        .font(.system(size: 44, weight: .heavy)).foregroundColor(runtime.theme.primary)
                    if !perLine.isEmpty { Text(perLine).font(.system(size: 14)).foregroundColor(runtime.theme.textSecondary) }
                }
                if let estimateLine {
                    Text(estimateLine).font(.system(size: 14, weight: .semibold))
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: runtime.theme.inputRadius).fill(runtime.theme.tint))
                }
                ForEach(features, id: \.self) { feature in
                    Label {
                        Text(feature).font(.system(size: 14))
                    } icon: {
                        Image(systemName: "checkmark.circle.fill").foregroundColor(runtime.theme.primary)
                    }
                }
                if !cta.isEmpty, !ctaPage.isEmpty || ctaURL != nil {
                    Button(cta) {
                        if !ctaPage.isEmpty { runtime.navigate(toPage: ctaPage) } else if let ctaURL { openURL(ctaURL) }
                    }
                    .buttonStyle(.bordered)
                    .tint(runtime.theme.primary)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cardShape)
            .cmsInspectorID("Cms.planSummary.plan")

            VStack(alignment: .leading, spacing: 0) {
                Text("Billing").font(.system(size: 13, weight: .bold)).foregroundColor(runtime.theme.textSecondary)
                    .padding(.bottom, 6)
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    if index > 0 { Divider() }
                    HStack(alignment: .firstTextBaseline) {
                        Text(row.0).font(.system(size: 14)).foregroundColor(runtime.theme.textSecondary)
                        Spacer(minLength: 12)
                        if index == 0 {
                            Text(row.1).font(.system(size: 12, weight: .bold))
                                .foregroundColor(overdue ? .white : runtime.theme.primary) // theme-exempt: text on the error pill
                                .padding(.horizontal, 10).padding(.vertical, 3)
                                .background(Capsule().fill(overdue ? runtime.theme.error : runtime.theme.tint))
                        } else {
                            Text(row.1).font(.system(size: 14, weight: .semibold)).multilineTextAlignment(.trailing)
                        }
                    }
                    .padding(.vertical, 9)
                }
                HStack(spacing: 8) {
                    Button { openPortal("manage") } label: {
                        HStack(spacing: 6) {
                            if busy == "manage" { ProgressView().controlSize(.small) }
                            Text(text("manageLabel", "Update in Stripe"))
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    Button { openPortal("invoices") } label: {
                        HStack(spacing: 6) {
                            if busy == "invoices" { ProgressView().controlSize(.small) }
                            Text(text("invoicesLabel", "View invoices"))
                        }
                    }
                    .buttonStyle(.borderless)
                }
                .tint(runtime.theme.primary)
                .disabled(busy != nil)
                .padding(.top, 10)
                if let actionError {
                    Text(actionError).font(.system(size: 13)).foregroundColor(runtime.theme.error).padding(.top, 6)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cardShape)
            .cmsInspectorID("Cms.planSummary.billing")
        })
    }

    // MARK: - billingFormat.ts

    private static let zeroDecimal: Set<String> = ["bif", "clp", "djf", "gnf", "jpy", "kmf", "krw", "mga", "pyg", "rwf", "ugx", "vnd", "vuv", "xaf", "xof", "xpf"]

    static func money(_ minor: Double, _ currency: String) -> String {
        let major = zeroDecimal.contains(currency.lowercased()) ? minor : minor / 100
        let whole = major.rounded() == major
        return major.formatted(.currency(code: currency.uppercased()).precision(.fractionLength(whole ? 0 : 2)))
    }

    static func date(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        if value.range(of: #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$"#, options: .regularExpression) != nil {
            return iso.date(from: value.replacingOccurrences(of: " ", with: "T") + "Z")
        }
        if let d = iso.date(from: value) { return d }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return iso.date(from: value)
    }

    static func longDate(_ value: String?) -> String? {
        date(value)?.formatted(.dateTime.day().month(.wide).year())
    }

    static func plural(_ unit: String, _ n: Int) -> String {
        if n == 1 || unit.isEmpty { return unit }
        return unit.lowercased().hasSuffix("s") ? unit : unit + "s"
    }

    /// `fillTokens`: nil when the text uses a token with no value.
    static func fill(_ text: String, _ values: [String: String?]) -> String? {
        var out = text
        for (key, value) in values where out.contains("{\(key)}") {
            guard let value else { return nil }
            out = out.replacingOccurrences(of: "{\(key)}", with: value)
        }
        return out
    }

    static func titleCase(_ s: String) -> String {
        s.replacingOccurrences(of: "_", with: " ").capitalized
    }

    static func statusLabel(_ status: String, _ cancelling: Bool) -> String {
        if cancelling && (status == "active" || status == "trialing") { return "Cancelling" }
        switch status {
        case "trialing": return "Free trial"
        case "active": return "Active"
        case "past_due", "unpaid": return "Payment overdue"
        case "incomplete": return "Awaiting payment"
        case "canceled", "incomplete_expired": return "Ended"
        case "paused": return "Paused"
        default: return status.isEmpty ? "Unknown" : titleCase(status)
        }
    }

    private static let brands = ["visa": "Visa", "mastercard": "Mastercard", "amex": "American Express", "discover": "Discover",
                                 "diners": "Diners Club", "jcb": "JCB", "unionpay": "UnionPay", "cartes_bancaires": "Cartes Bancaires",
                                 "link": "Link", "sepa_debit": "SEPA Direct Debit", "bacs_debit": "Bacs Direct Debit",
                                 "us_bank_account": "Bank account", "au_becs_debit": "BECS Direct Debit"]
    private static let wallets = ["apple_pay": "Apple Pay", "google_pay": "Google Pay", "samsung_pay": "Samsung Pay", "link": "Link"]

    static func paymentMethod(_ pm: [String: CmsJSON]?) -> String? {
        guard let pm, let brandKey = pm.string("brand") else { return nil }
        let brand = brands[brandKey] ?? titleCase(brandKey)
        let last4 = pm.string("last4")
        let card = last4.map { "\(brand) ···· \($0)" } ?? brand
        if let wallet = pm.string("wallet"), wallet != brandKey {
            let w = wallets[wallet] ?? titleCase(wallet)
            return last4 != nil ? "\(w) · \(card)" : w
        }
        return card
    }
}
