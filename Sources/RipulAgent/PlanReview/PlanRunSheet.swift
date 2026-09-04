import SwiftUI

/// Start an agent run against a plan.
///
/// Three choices, in the order they matter: what the run should do, which model
/// does it, and the exact prompt.
///
/// The prompt is **shown and editable** rather than hidden behind the intent
/// buttons. A run costs tokens and acts on the repo, so the instruction that
/// will actually be sent should be visible before it is — and the generated
/// text names the plan path and tells the agent to call `planStatus` first,
/// which is what keeps its comments anchored to real sections.
@available(iOS 17.0, macOS 14.0, *)
struct PlanRunSheet: View {
    let planTitle: String
    let models: [ModelInfo]
    /// Pin storage for the model picker. Nil ⇒ the picker still works, it just
    /// has no Pinned section — see `ModelPickerList`.
    let cache: RipulSessionCache?
    /// The plan's link key. When set (and cache is present), starting a run
    /// remembers the chosen model per plan — what makes the checkpoint
    /// control's subsequent rounds one tap.
    let modelMemoryKey: String?
    /// Regenerates the prompt when the intent changes.
    let promptFor: (String) async -> String
    /// (modelId, prompt, title) — title is "<Verb>: <plan>", the session name.
    let onStart: (String, String, String) async -> PlanRunStartResult

    @State private var intent: String
    @State private var modelId: String = ""
    @State private var prompt = ""
    @State private var loadingPrompt = true
    @State private var starting = false
    @State private var failure: String?
    @Environment(\.dismiss) private var dismiss

    init(
        planTitle: String,
        models: [ModelInfo],
        cache: RipulSessionCache? = nil,
        modelMemoryKey: String? = nil,
        initialIntent: String = "review",
        promptFor: @escaping (String) async -> String,
        onStart: @escaping (String, String, String) async -> PlanRunStartResult
    ) {
        self.planTitle = planTitle
        self.models = models
        self.cache = cache
        self.modelMemoryKey = modelMemoryKey
        self.promptFor = promptFor
        self.onStart = onStart
        _intent = State(initialValue: initialIntent)
    }

    private static let intents: [(id: String, label: String, hint: String)] = [
        ("draft", "Draft", "Write the plan: turn the problem statement into an approach."),
        ("review", "Review", "Read the plan and file comments on what is wrong or missing."),
        ("address", "Address comments", "Revise the plan to answer the open comments."),
        ("implement", "Do the tasks", "Carry out the open tasks and mark them done."),
    ]

    private var hint: String {
        Self.intents.first { $0.id == intent }?.hint ?? ""
    }

    /// The new session's name: the job, then the plan. "Review: Share links"
    /// beats the default auto-title in any session list.
    private var runTitle: String {
        let verb: String
        switch intent {
        case "draft": verb = "Draft"
        case "address": verb = "Address"
        case "implement": verb = "Implement"
        default: verb = "Review"
        }
        return "\(verb): \(planTitle)"
    }

    private var selectedModelName: String {
        models.first { $0.id == modelId }?.name ?? "Choose"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    // Menu, not segmented: four intents with long labels do
                    // not fit iPhone-width segments.
                    Picker("Intent", selection: $intent) {
                        ForEach(Self.intents, id: \.id) { option in
                            Text(option.label).tag(option.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .uiKitIdentifier("PlanRunSheet.intentPicker")
                } header: {
                    Text("Run")
                } footer: {
                    Text(hint)
                }

                Section("Model") {
                    if models.isEmpty {
                        Text("No models available yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        // Drills into the shared picker rather than a flat menu:
                        // a run costs tokens against one account or another, and
                        // that picker is where the billing split is spelled out.
                        NavigationLink {
                            ModelPickerPushList(
                                models: models,
                                cache: cache,
                                selectedId: modelId,
                                identifierPrefix: "PlanRunSheet",
                                onPick: { modelId = $0.id }
                            )
                        } label: {
                            HStack {
                                Text("Model")
                                Spacer()
                                Text(selectedModelName)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .uiKitIdentifier("PlanRunSheet.modelPicker")
                    }
                }

                Section {
                    if loadingPrompt {
                        HStack { ProgressView().controlSize(.small); Text("Building prompt…") }
                    } else {
                        TextField("Prompt", text: $prompt, axis: .vertical)
                            .lineLimit(6...20)
                            .font(.callout)
                            .uiKitIdentifier("PlanRunSheet.promptField")
                    }
                } header: {
                    Text("Prompt")
                } footer: {
                    Text("Sent as the first message of a new session, in this plan's working directory.")
                }

                if let failure {
                    Section {
                        Text(failure).foregroundStyle(.red).font(.callout)
                    }
                }
            }
            .navigationTitle("Run on \(planTitle)")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if starting {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Start") { start() }
                            .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                      || modelId.isEmpty)
                            .uiKitIdentifier("PlanRunSheet.startButton")
                    }
                }
            }
            .task {
                applyDefaultModel()
                await refreshPrompt()
            }
            // The catalog is fetched lazily, and `promptFor` is what triggers the fetch — so
            // on the very first open `models` is still empty when `.task` runs above, the
            // default selects nothing, and Start stays disabled until the user picks a model
            // by hand. Apply the default again when the catalog actually arrives.
            .onChange(of: models) { _, _ in
                applyDefaultModel()
            }
            .onChange(of: intent) { _, _ in
                Task { await refreshPrompt() }
            }
        }
    }

    /// First enabled model, unless the user has already chosen one — a manual pick must
    /// survive the catalog arriving late.
    private func applyDefaultModel() {
        guard modelId.isEmpty else { return }
        modelId = models.first(where: { $0.enabled })?.id ?? ""
    }

    private func refreshPrompt() async {
        loadingPrompt = true
        prompt = await promptFor(intent)
        loadingPrompt = false
    }

    private func start() {
        guard !starting else { return }
        starting = true
        failure = nil
        let (model, text) = (modelId, prompt)
        // Remember the pick PER ROLE per plan so the checkpoint's next rounds
        // of the same kind are one tap — but each role's FIRST run still
        // asks: the reviewer model is a separate decision from the drafter's
        // (cheap drafter + strong reviewer is a normal split). Saved on
        // Start, not selection — an abandoned sheet remembers nothing.
        if let modelMemoryKey, let cache {
            cache.set(model, forKey: "planRunModel:\(modelMemoryKey):\(intent)")
        }
        Task {
            let result = await onStart(model, text, runTitle)
            // Durable role state, recorded BY THE STARTER: the checkpoint's
            // kick and turn logic read these instead of re-deriving identity
            // from session titles, which auto-retitling silently breaks.
            if result.error == nil, let key = modelMemoryKey, let cache {
                if let chatId = result.chatId {
                    if intent == "draft" || intent == "address" {
                        cache.set(chatId, forKey: "planAuthor:\(key)")
                    } else if intent == "review" {
                        // A sheet-started review REPLACES the recorded
                        // reviewer — fresh eyes on demand, and the checkpoint
                        // kicks this session from the next round on.
                        cache.set(chatId, forKey: "planReviewer:\(key)")
                    }
                }
                cache.set(intent == "review" ? "reviewer" : "author", forKey: "planLastActor:\(key)")
            }
            // A non-nil error is the reason it did not start. Staying open with
            // the message beats dismissing onto a session that is not running.
            if let error = result.error {
                failure = error
                starting = false
            } else {
                starting = false
                dismiss()
            }
        }
    }
}
