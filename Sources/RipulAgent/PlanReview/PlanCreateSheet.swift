import SwiftUI

/// Name a new plan.
///
/// Title only. A plan is a prose document an agent fills in — asking for
/// sections up front would be inventing structure the author has not decided
/// yet, and the starter body already provides enough headings to anchor the
/// first round of review against.
///
/// The filename is shown live because it is derived from the title and is what
/// everything else addresses the plan by. Seeing it before committing is the
/// difference between `row-billing` and `row-billing-v2-final`.
@available(iOS 17.0, macOS 14.0, *)
public struct PlanCreateSheet: View {
    /// (title, problem, draftAfter) — `problem` seeds the Problem section;
    /// `draftAfter` asks the host to flow straight into a drafting run.
    let onCreate: (String, String?, Bool) async -> Void

    @State private var title = ""
    @State private var problem = ""
    @State private var working = false
    @Environment(\.dismiss) private var dismiss
    @FocusState private var titleFocused: Bool

    public init(onCreate: @escaping (String, String?, Bool) async -> Void) {
        self.onCreate = onCreate
    }

    private var trimmed: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Mirrors `slugifyHeading` in the web layer closely enough to preview the
    /// filename. Deliberately display-only — the web layer computes the real
    /// slug, so a drift here shows a slightly wrong preview rather than
    /// creating the wrong file.
    private var previewSlug: String {
        let lowered = trimmed.lowercased()
        let mapped = lowered.map { ch -> Character in
            (ch.isLetter && ch.isASCII) || ch.isNumber ? ch : "-"
        }
        let collapsed = String(mapped)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return collapsed
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Plan title", text: $title)
                        .focused($titleFocused)
                        .submitLabel(.done)
                        .onSubmit { if !trimmed.isEmpty { create(draftAfter: false) } }
                        .uiKitIdentifier("PlanCreateSheet.titleField")
                } footer: {
                    if !previewSlug.isEmpty {
                        Text("docs/plans/\(previewSlug).md")
                            .font(.caption)
                            .monospaced()
                    } else {
                        Text("Creates a plan document with Problem, Approach and Open questions sections.")
                    }
                }

                Section {
                    TextField(
                        "What's the problem?",
                        text: $problem,
                        axis: .vertical
                    )
                    .lineLimit(3...8)
                    .uiKitIdentifier("PlanCreateSheet.problemField")
                } footer: {
                    Text("Seeds the Problem section. An agent drafts the Approach and Open questions from it — you review, it writes.")
                }

                Section {
                    Button {
                        create(draftAfter: true)
                    } label: {
                        Label("Create & draft with agent", systemImage: "play.circle.fill")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(trimmed.isEmpty || working)
                    .uiKitIdentifier("PlanCreateSheet.createAndDraft")
                }
            }
            .navigationTitle("New plan")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if working {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Create") { create(draftAfter: false) }
                            .disabled(trimmed.isEmpty)
                            .uiKitIdentifier("PlanCreateSheet.createButton")
                    }
                }
            }
            .onAppear { titleFocused = true }
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #endif
    }

    private func create(draftAfter: Bool) {
        guard !trimmed.isEmpty, !working else { return }
        working = true
        let name = trimmed
        let statement = problem.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            await onCreate(name, statement.isEmpty ? nil : statement, draftAfter)
            working = false
            dismiss()
        }
    }
}
