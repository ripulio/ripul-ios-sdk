import SwiftUI

/// Write a comment against a plan.
///
/// The anchor is a **picker over real sections**, never a text field. A
/// hand-typed slug orphans the moment it is submitted, and the orphan signal is
/// only worth reading because it is rare — one careless free-text field would
/// turn it into noise and take the review's integrity with it.
///
/// Severity defaults to `blocking`. A person taking the trouble to write a
/// comment is usually stating a requirement, not an observation, and the cost
/// of a wrong default is one tap versus a requirement that silently fails to
/// hold the plan open.
@available(iOS 17.0, macOS 14.0, *)
struct PlanCommentSheet: View {
    let anchors: [PlanAnchor]
    /// Pre-selected section, when the sheet was opened from one.
    let initialAnchor: String
    let onSubmit: (String, PlanSeverity, String) async -> Void

    @State private var anchor: String
    @State private var severity: PlanSeverity = .blocking
    @State private var body_ = ""
    @State private var working = false
    @Environment(\.dismiss) private var dismiss
    @FocusState private var bodyFocused: Bool

    init(
        anchors: [PlanAnchor],
        initialAnchor: String = PlanAnchorConstants.planWide,
        onSubmit: @escaping (String, PlanSeverity, String) async -> Void
    ) {
        self.anchors = anchors
        self.initialAnchor = initialAnchor
        self.onSubmit = onSubmit
        _anchor = State(initialValue: initialAnchor)
    }

    private var trimmed: String { body_.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section("Against") {
                    Picker("Section", selection: $anchor) {
                        Text("The plan as a whole").tag(PlanAnchorConstants.planWide)
                        ForEach(anchors) { section in
                            Text(section.heading).tag(section.slug)
                        }
                    }
                    .uiKitIdentifier("PlanCommentSheet.anchorPicker")
                }

                Section {
                    Picker("Severity", selection: $severity) {
                        Text("Blocking").tag(PlanSeverity.blocking)
                        Text("Should fix").tag(PlanSeverity.shouldFix)
                        Text("Nit").tag(PlanSeverity.nit)
                    }
                    .pickerStyle(.segmented)
                    .uiKitIdentifier("PlanCommentSheet.severityPicker")
                } header: {
                    Text("Severity")
                } footer: {
                    Text(severity == .blocking
                         ? "Holds the plan open until it is resolved or declined."
                         : "Recorded, but does not hold the plan open.")
                }

                Section("Comment") {
                    TextField("What needs to change, and why", text: $body_, axis: .vertical)
                        .lineLimit(4...12)
                        .focused($bodyFocused)
                        .uiKitIdentifier("PlanCommentSheet.bodyField")
                }
            }
            .navigationTitle("New comment")
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
                        Button("Add") { submit() }
                            .disabled(trimmed.isEmpty)
                            .uiKitIdentifier("PlanCommentSheet.addButton")
                    }
                }
            }
            .onAppear { bodyFocused = true }
        }
    }

    private func submit() {
        guard !trimmed.isEmpty, !working else { return }
        working = true
        let (a, sev, text) = (anchor, severity, trimmed)
        Task {
            await onSubmit(a, sev, text)
            working = false
            dismiss()
        }
    }
}

/// Record work owed.
///
/// `fromComment` is set when the sheet is opened from a comment, which is the
/// path that makes review output into implementation input without retyping.
@available(iOS 17.0, macOS 14.0, *)
struct PlanTaskSheet: View {
    /// Shown so it is obvious which comment this discharges, when there is one.
    let sourceComment: PlanComment?
    let onSubmit: (String, String?) async -> Void

    @State private var title = ""
    @State private var owner = ""
    @State private var working = false
    @Environment(\.dismiss) private var dismiss
    @FocusState private var titleFocused: Bool

    private var trimmed: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                if let sourceComment {
                    Section("Discharges") {
                        Text(sourceComment.body)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    TextField("What needs doing", text: $title, axis: .vertical)
                        .lineLimit(2...6)
                        .focused($titleFocused)
                        .uiKitIdentifier("PlanTaskSheet.titleField")
                    TextField("Owner (optional)", text: $owner)
                        .uiKitIdentifier("PlanTaskSheet.ownerField")
                } footer: {
                    Text("Marking a task done does not close the comment it came from — the reviewer who raised it decides that.")
                }
            }
            .navigationTitle("New task")
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
                        Button("Add") { submit() }
                            .disabled(trimmed.isEmpty)
                            .uiKitIdentifier("PlanTaskSheet.addButton")
                    }
                }
            }
            .onAppear { titleFocused = true }
        }
        #if os(iOS)
        .presentationDetents([.medium])
        #endif
    }

    private func submit() {
        guard !trimmed.isEmpty, !working else { return }
        working = true
        let (text, who) = (trimmed, owner.trimmingCharacters(in: .whitespacesAndNewlines))
        Task {
            await onSubmit(text, who.isEmpty ? nil : who)
            working = false
            dismiss()
        }
    }
}

/// Shared anchor constants, mirroring `PLAN_ANCHOR` in the web layer.
public enum PlanAnchorConstants {
    /// Addresses the plan as a whole rather than one section.
    public static let planWide = "__plan__"
}
