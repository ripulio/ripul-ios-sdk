import Charts
import SwiftUI

/// ElevenLabs plan, credits and billing for whichever key the caller holds —
/// the account key (Profile, via the worker) or the device key (Settings →
/// Voice, direct). Quota renders with the Claude/Codex account view.
@available(iOS 26.0, macOS 26.0, *)
struct ElevenLabsUsageScreen: View {
    let load: () async throws -> ElevenLabsUsage

    @State private var usage: ElevenLabsUsage?
    @State private var error: String?
    @State private var loading = false

    var body: some View {
        Form {
            Section {
                if let usage {
                    CodingAccountUsageView(usage: usage.quota)
                    if let used = usage.creditsUsed, let limit = usage.creditsLimit {
                        LabeledContent("Credits used", value: "\(used.formatted()) of \(limit.formatted())")
                            .uiKitIdentifier("ElevenLabsUsage.credits")
                    }
                } else if loading {
                    HStack(spacing: 8) { ProgressView(); Text("Checking…").foregroundStyle(.secondary) }
                }
                if let error {
                    Text(error).font(.caption).foregroundStyle(.red).uiKitIdentifier("ElevenLabsUsage.error")
                }
            } header: {
                Text("Plan")
            }
            if let usage { billing(usage); daily(usage) }
            Section {
                Link(destination: URL(string: "https://elevenlabs.io/app/subscription")!) {
                    Label("Manage subscription", systemImage: "arrow.up.right.square")
                }.uiKitIdentifier("ElevenLabsUsage.manage")
            } footer: {
                Text("Figures come straight from ElevenLabs. Invoices, payment methods and plan changes live in your ElevenLabs account.")
            }
        }
        .navigationTitle("ElevenLabs Usage")
        #if os(macOS)
        .formStyle(.grouped)
        #endif
        .toolbar {
            Button { Task { await refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .disabled(loading).uiKitIdentifier("ElevenLabsUsage.refresh")
        }
        .refreshable { await refresh() }
        .task { await refresh() }
    }

    @ViewBuilder private func billing(_ usage: ElevenLabsUsage) -> some View {
        Section("Billing") {
            if let status = usage.statusName {
                LabeledContent("Status") {
                    Text(status).foregroundStyle(usage.status == "past_due" || usage.status == "incomplete" ? .red : .secondary)
                }
            }
            if let period = usage.billingPeriodName { LabeledContent("Billed", value: period) }
            if let invoice = usage.nextInvoice {
                LabeledContent("Next invoice", value: invoice.amountDue.formatted(.currency(code: invoice.currency)))
                    .uiKitIdentifier("ElevenLabsUsage.nextInvoice")
                if let due = invoice.dueAt {
                    LabeledContent("Due", value: due.formatted(date: .abbreviated, time: .omitted))
                }
            } else {
                LabeledContent("Next invoice", value: "None scheduled")
            }
            if usage.openInvoiceCount > 0 {
                LabeledContent("Unpaid invoices") { Text("\(usage.openInvoiceCount)").foregroundStyle(.red) }
            }
        }
        .uiKitIdentifier("ElevenLabsUsage.billing")
    }

    @ViewBuilder private func daily(_ usage: ElevenLabsUsage) -> some View {
        Section {
            if let days = usage.daily, !days.isEmpty {
                LabeledContent("Last 30 days", value: "\(Int(usage.dailyTotal).formatted()) credits")
                Chart(days) { day in
                    BarMark(x: .value("Day", day.date, unit: .day), y: .value("Credits", day.credits))
                }
                .chartYAxis { AxisMarks(position: .leading) }
                .frame(height: 160)
                .accessibilityLabel("Daily credit usage, last 30 days")
                .uiKitIdentifier("ElevenLabsUsage.chart")
            } else if usage.daily == nil {
                Text("Daily usage needs a key with usage read access.").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("No usage in the last 30 days.").font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Daily usage")
        }
    }

    private func refresh() async {
        loading = true; error = nil
        defer { loading = false }
        do { usage = try await load() }
        catch is CancellationError {}
        catch { self.error = error.localizedDescription }
    }
}
