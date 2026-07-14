import SwiftUI

/// A compact pinned lozenge showing the current TodoWrite state for a chat.
///
/// Inserted into the chat title bar on iOS and macOS. Tap opens a sheet
/// (iOS) or popover (macOS) with the full checklist and a Dismiss button.
/// Dismissal is scoped to the current version — a new TodoWrite update
/// re-shows the lozenge automatically.
@available(iOS 15.0, macOS 13.0, *)
@MainActor
public struct TodoLozenge: View {
    @ObservedObject var bridge: AgentBridge
    // Observe the session-list store directly: the todo maps live there now, so
    // the lozenge must observe it to re-render on todo updates (observing
    // `bridge` no longer sees these changes).
    @ObservedObject private var store: SessionListStore
    let chatId: String
    @State private var showingExpanded = false

    public init(bridge: AgentBridge, chatId: String) {
        self.bridge = bridge
        self._store = ObservedObject(wrappedValue: bridge.sessionList)
        self.chatId = chatId
    }

    public var body: some View {
        Group {
            if let state = bridge.visibleTodoState(for: chatId) {
                lozengeButton(state: state)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: store.todoStates[chatId]?.version ?? -1)
        .animation(.easeInOut(duration: 0.2), value: store.dismissedTodoVersions[chatId] ?? -1)
    }

    @ViewBuilder
    private func lozengeButton(state: TodoState) -> some View {
        let completed = state.todos.filter { $0.status == "completed" }.count
        let total = state.todos.count
        let inProgress = state.todos.first(where: { $0.status == "in_progress" })
        let allDone = completed == total && total > 0

        Button {
            showingExpanded = true
        } label: {
            // Mirror sessionInfoPanel structure: 2-line VStack with matching
            // paddings so the TodoLozenge has the same height as the title
            // lozenge it sits beside.
            VStack(spacing: 1) {
                HStack(spacing: 4) {
                    Image(systemName: allDone ? "checkmark.circle.fill" : "list.bullet.clipboard")
                        .font(.caption2)
                    Text("\(completed)/\(total)")
                        .font(.caption2.monospacedDigit())
                }
                .foregroundStyle(allDone ? Color.green : Color.secondary)

                Text(allDone ? "Plan done" : (inProgress?.activeForm ?? inProgress?.content ?? "Plan"))
                    .font(.caption)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(allDone ? Color.green : Color.primary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .modifier(GlassPillModifier())
        }
        .buttonStyle(.plain)
        #if os(iOS)
        .sheet(isPresented: $showingExpanded) {
            NavigationView {
                TodoListExpandedView(state: state) {
                    bridge.dismissTodoState(chatId: chatId)
                    showingExpanded = false
                }
                .navigationBarTitleDisplayMode(.inline)
                .navigationTitle("Plan")
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Done") { showingExpanded = false }
                    }
                }
            }
        }
        #else
        .popover(isPresented: $showingExpanded, arrowEdge: .bottom) {
            TodoListExpandedView(state: state) {
                bridge.dismissTodoState(chatId: chatId)
                showingExpanded = false
            }
            .frame(width: 340, height: 420)
        }
        #endif
        .transition(.opacity.combined(with: .scale))
    }
}

/// Full checklist view shown inside the lozenge's sheet (iOS) or popover (macOS).
/// Uses native `List` + `Section` + `ProgressView` for an iOS-native feel —
/// inset-grouped styling on iOS, inset on macOS.
@available(iOS 15.0, macOS 13.0, *)
@MainActor
public struct TodoListExpandedView: View {
    let state: TodoState
    let onDismiss: () -> Void

    public init(state: TodoState, onDismiss: @escaping () -> Void) {
        self.state = state
        self.onDismiss = onDismiss
    }

    public var body: some View {
        let completed = state.todos.filter { $0.status == "completed" }.count
        let total = state.todos.count
        let fraction = total > 0 ? Double(completed) / Double(total) : 0

        List {
            Section {
                ForEach(Array(state.todos.enumerated()), id: \.offset) { _, todo in
                    TodoRow(todo: todo)
                }
            } header: {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(completed) of \(total) complete")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    ProgressView(value: fraction)
                        .tint(.green)
                }
                .textCase(nil)
                .padding(.vertical, 6)
            }

            Section {
                Button(role: .destructive, action: onDismiss) {
                    Label("Clear plan", systemImage: "xmark.circle")
                        .frame(maxWidth: .infinity)
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
    }
}

@available(iOS 15.0, macOS 13.0, *)
private struct TodoRow: View {
    let todo: TodoItem

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(todo.content)
                    .strikethrough(todo.status == "completed")
                    .font(.body)
                    .foregroundStyle(todo.status == "completed" ? Color.secondary : Color.primary)
                if todo.status == "in_progress", let activeForm = todo.activeForm {
                    Text(activeForm)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        } icon: {
            statusIcon
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch todo.status {
        case "completed":
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case "in_progress":
            Image(systemName: "circle.lefthalf.filled")
                .foregroundStyle(.blue)
        default:
            Image(systemName: "circle")
                .foregroundStyle(.secondary)
        }
    }
}
