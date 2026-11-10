#if os(iOS)
import SwiftUI

/// Draws `CmsRuntime.pendingAfter`: a full-screen countdown in the brand
/// gradient (WAC's 3-2-1 after WAC in), then the summary as a sheet (WAC's
/// "Shift completed"), then the page `after.open` names. Between the two,
/// `after.round` asks to round the saved times (WAC's "Round shift times?").
struct CmsMutationAfterOverlay: ViewModifier {
    @ObservedObject var runtime: CmsRuntime
    @State private var counting: CmsRuntime.PendingAfter?
    @State private var count = 0
    @State private var summary: CmsRuntime.PendingAfter?
    @State private var rounding: RoundStage?
    @State private var applying = false

    /// The round step's question: what it would change, from the shared rules.
    struct RoundStage: Identifiable {
        let id = UUID()
        let pending: CmsRuntime.PendingAfter
        let round: CmsMutationAfter.Round
        let start: Date
        let end: Date
        let q: CmsMutationAfter.Quantised
    }

    func body(content: Content) -> some View {
        content
            .onReceive(runtime.$pendingAfter) { pending in
                guard let pending else { return }
                runtime.pendingAfter = nil
                // The form that ran the mutation is still closing: present
                // once it has gone (a cover over a closing sheet doesn't show).
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    if let n = pending.after.countdown {
                        count = n
                        counting = pending
                    } else {
                        afterCountdown(pending)
                    }
                }
            }
            .fullScreenCover(item: $counting) { pending in
                countdown(pending)
                    .presentationBackground(.clear)
            }
            .alert(rounding?.round.title ?? "", isPresented: Binding(get: { rounding != nil }, set: { if !$0, !applying { skipRound() } }), presenting: rounding) { stage in
                Button("Apply") { apply(stage) }
                    .cmsInspectorID("Cms.afterRound.apply")
                // The cancel role, so the system adds no Cancel of its own.
                Button("Keep exact", role: .cancel) { skipRound() }
                    .cmsInspectorID("Cms.afterRound.keep")
                Button("Turn off", role: .destructive) {
                    CmsMutationAfter.setRounding(stage.round.setting, on: false)
                    skipRound()
                }
                .cmsInspectorID("Cms.afterRound.off")
            } message: { stage in
                Text(roundLines(stage))
            }
            .ripulSheet(item: $summary, size: .form) { pending in
                summarySheet(pending)
            }
    }

    private func finish(_ pending: CmsRuntime.PendingAfter) {
        if let page = pending.after.openPage { runtime.navigate(toPage: page) }
    }

    @ViewBuilder
    private func countdown(_ pending: CmsRuntime.PendingAfter) -> some View {
        ZStack {
            runtime.theme.gradient.ignoresSafeArea()
            VStack(spacing: 16) {
                Text("\(count)")
                    .font(.system(size: 160, weight: .heavy).monospacedDigit())
                    .foregroundStyle(runtime.theme.color(role: .paper))
                    .contentTransition(.numericText(countsDown: true))
                    .id(count)
                    .transition(.asymmetric(insertion: .scale(scale: 1.4).combined(with: .opacity), removal: .opacity))
                if let text = pending.after.countdownText {
                    Text(text)
                        .font(.ripul(.title3))
                        .foregroundStyle(runtime.theme.color(role: .paper).opacity(0.9))
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { end(pending) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
        .task(id: pending.id) {
            while count > 1 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard counting?.id == pending.id else { return }
                withAnimation(.easeOut(duration: 0.35)) { count -= 1 }
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if counting?.id == pending.id { end(pending) }
        }
    }

    private func end(_ pending: CmsRuntime.PendingAfter) {
        counting = nil
        // Let the cover go before the alert or sheet comes up.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { afterCountdown(pending) }
    }

    /// The round step (when it would change something), else the summary, else the page.
    private func afterCountdown(_ pending: CmsRuntime.PendingAfter) {
        if let stage = roundStage(pending) { rounding = stage } else { toSummary(pending) }
    }

    private func toSummary(_ pending: CmsRuntime.PendingAfter) {
        if pending.after.summary != nil { summary = pending } else { finish(pending) }
    }

    private static func date(_ text: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: text) { return d }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: text)
    }

    /// What rounding would change, or nil when it is off or changes nothing (the web's roundPlan).
    private func roundStage(_ pending: CmsRuntime.PendingAfter) -> RoundStage? {
        guard let r = pending.after.round else { return nil }
        let setting = CmsMutationAfter.roundingSetting(r.setting)
        guard setting.on else { return nil }
        let run = CmsJSON.object(["result": pending.result ?? .null])
        func time(_ t: String?) -> Date? { t.flatMap { Self.date(CmsMutationAfter.fill($0, run: run).text) } }
        guard let start = time(r.start), let end = time(r.end) else { return nil }
        let q = CmsMutationAfter.quantise(start: start, end: end, plannedStart: time(r.plannedStart), plannedEnd: time(r.plannedEnd),
                                          windowMinutes: setting.windowMinutes, granularityMinutes: r.granularityMinutes)
        guard q.startChanged || q.endChanged else { return nil }
        return RoundStage(pending: pending, round: r, start: start, end: end, q: q)
    }

    private func roundLines(_ stage: RoundStage) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return [
            stage.q.startChanged ? "Start  \(f.string(from: stage.start)) → \(f.string(from: stage.q.start))" : nil,
            stage.q.endChanged ? "End  \(f.string(from: stage.end)) → \(f.string(from: stage.q.end))" : nil,
        ].compactMap { $0 }.joined(separator: "\n")
    }

    private func skipRound() {
        guard let stage = rounding else { return }
        rounding = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { toSummary(stage.pending) }
    }

    /// Runs `apply.run` with `{start}` and `{end}` as the rounded times; the
    /// summary then shows the record as saved after rounding when the call returns it.
    private func apply(_ stage: RoundStage) {
        applying = true
        rounding = nil
        let iso = ISO8601DateFormatter()
        let run = CmsJSON.object(["result": stage.pending.result ?? .null,
                                  "start": .string(iso.string(from: stage.q.start)),
                                  "end": .string(iso.string(from: stage.q.end))])
        let inputs = runtime.mutationDefs[stage.round.applyRun]?.action?.inputs ?? []
        var params: [String: CmsJSON] = [:]
        for (name, template) in stage.round.applyInputs {
            let type = inputs.first { $0.name == name }?.type ?? "string"
            let known = ["integer", "float", "boolean", "timestamp", "date"].contains(type) ? type : "string"
            params[name] = .object(["value": .string(CmsMutationAfter.fill(template, run: run).text), "type": .string(known)])
        }
        Task { @MainActor in
            let result = await runtime.runMutationResult(stage.round.applyRun, params: params)
            applying = false
            var next = stage.pending
            if case .success(let saved?) = result, case .object = saved {
                next = CmsRuntime.PendingAfter(after: stage.pending.after, result: saved)
            }
            toSummary(next)
        }
    }

    @ViewBuilder
    private func summarySheet(_ pending: CmsRuntime.PendingAfter) -> some View {
        let run = CmsJSON.object(["result": pending.result ?? .null])
        let s = pending.after.summary!
        NavigationStack {
            List {
                if let subtitle = s.subtitle {
                    let text = CmsMutationAfter.fill(subtitle, run: run).text
                    if !text.isEmpty {
                        Text(text).font(.ripul(.headline)).foregroundStyle(.ripul(.textSecondary))
                    }
                }
                Section {
                    ForEach(Array(s.lines.enumerated()), id: \.offset) { _, line in
                        let filled = CmsMutationAfter.fill(line.value, run: run)
                        if !filled.missing, !filled.text.trimmingCharacters(in: .whitespaces).isEmpty {
                            LabeledContent(line.label) {
                                Text(filled.text).monospacedDigit().fontWeight(.semibold)
                            }
                        }
                    }
                }
            }
            .navigationTitle(CmsMutationAfter.fill(s.title, run: run).text)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(s.done ?? "Done") {
                        summary = nil
                        finish(pending)
                    }
                    .cmsInspectorID("Cms.afterSummary.done")
                }
            }
        }
        .cmsInspectorID("Cms.afterSummary")
    }
}
#endif
