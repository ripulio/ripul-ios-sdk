#if os(iOS)
import SwiftUI

@MainActor
struct ThemePublishReviewScreen: View {
    @ObservedObject var model: ThemeManagementModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var search = ""
    @State private var category: ThemeChangePresentation.Category?
    @State private var kind: ThemeDocumentChanges.Kind?
    @State private var confirmPublish = false
    @State private var reviewedDocument: Data?
    @State private var publicationCount = 0

    private var entries: [ThemeChangePresentation] {
        ThemeDocumentChanges.compare(model.baseline, model.data).map { ThemeChangePresentation($0) }
    }
    private func matches(_ entry: ThemeChangePresentation) -> Bool {
        (category == nil || entry.category == category) && (kind == nil || entry.change.kind == kind) &&
        (search.isEmpty || entry.searchable.localizedCaseInsensitiveContains(search))
    }
    var body: some View {
        let all = entries
        let filtered = all.filter(matches)
        NavigationStack {
            Group {
                if model.published { success }
                else { review(all: all, filtered: filtered) }
            }
            .navigationTitle(model.published ? "Theme published" : "Review changes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(model.published ? "Done" : "Keep editing") { dismiss() }
                        .disabled(model.busy).accessibilityIdentifier("ThemeReview.close")
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !model.published { publicationBar(count: all.count, filtered: filtered.count) }
            }
            .confirmationDialog("Publish \(publicationCount) \(publicationCount == 1 ? "change" : "changes")?", isPresented: $confirmPublish, titleVisibility: .visible) {
                Button("Publish to \(model.themeID ?? "theme")") {
                    guard let reviewedDocument else { return }
                    Task { await model.publish(reviewed: reviewedDocument) }
                }.accessibilityIdentifier("ThemeReview.confirmPublish")
                Button("Continue reviewing", role: .cancel) {}
            } message: {
                Text("This updates the theme for every app using \(model.themeID ?? "this theme"). Apps receive it on their next refresh.")
            }
        }
        .interactiveDismissDisabled(model.busy)
    }
    private func review(all: [ThemeChangePresentation], filtered: [ThemeChangePresentation]) -> some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text("\(all.count) \(all.count == 1 ? "change" : "changes") to review").font(.title3.weight(.bold))
                    LabeledContent("Publishing to", value: model.themeID ?? "Local theme").font(.subheadline)
                    if Set(all.map { $0.change.kind }).count > 1 {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 12) { counts(all) }
                            VStack(alignment: .leading, spacing: 8) { counts(all) }
                        }
                    }
                    if dynamicTypeSize.isAccessibilitySize {
                        Text("Apps receive this theme on their next refresh.").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 6)
            }
            if let error = model.error {
                Section {
                    Label("Review needs attention", systemImage: "exclamationmark.circle").font(.headline)
                    Text(error).font(.subheadline).textSelection(.enabled)
                    Text("Your draft is saved. Keep editing to make corrections or reload the server version.").font(.footnote).foregroundStyle(.secondary)
                }.accessibilityIdentifier("ThemeReview.error")
            }
            if let title = model.undoTitle, model.canUndoDiscard {
                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Change discarded").font(.subheadline.weight(.semibold))
                            Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer()
                        Button("Undo") { model.undoDiscard() }.accessibilityIdentifier("ThemeReview.undo")
                    }
                }
            }
            if !all.isEmpty {
                Section {
                    HStack(spacing: 6) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                filterPill("All", selected: category == nil) { category = nil }
                                ForEach(ThemeChangePresentation.Category.allCases, id: \.self) { item in
                                    if all.contains(where: { $0.category == item }) {
                                        filterPill(item.rawValue, selected: category == item) { category = item }
                                    }
                                }
                            }.padding(.vertical, 2)
                        }
                        Menu {
                            Picker("Change type", selection: $kind) {
                                Text("All changes").tag(Optional<ThemeDocumentChanges.Kind>.none)
                                ForEach(ThemeDocumentChanges.Kind.allCases, id: \.self) { Text($0.rawValue).tag(Optional($0)) }
                            }
                        } label: {
                            Image(systemName: kind == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                                .font(.title3).frame(minWidth: 44, minHeight: 44)
                        }
                        .accessibilityLabel("Change type: " + (kind?.rawValue ?? "All changes"))
                        .accessibilityIdentifier("ThemeReview.changeType")
                    }
                    if let kind { Text("Showing \(kind.rawValue.lowercased()) values").font(.caption).foregroundStyle(.secondary) }
                }
                ForEach(ThemeChangePresentation.Category.allCases, id: \.self) { group in
                    let items = filtered.filter { $0.category == group }
                    if !items.isEmpty {
                        Section {
                            ForEach(items) { entry in
                                NavigationLink {
                                    ThemeReviewChangeScreen(entry: entry, model: model)
                                } label: {
                                    ThemeReviewChangeCard(entry: entry, baseline: model.baseline, draft: model.data)
                                }
                                .disabled(model.busy)
                                .accessibilityIdentifier("ThemeReview.change." + entry.id)
                            }
                        } header: { Text("\(group.rawValue) · \(items.count)") }
                    }
                }
            }
            if filtered.isEmpty {
                Section {
                    ContentUnavailableView(all.isEmpty ? "No changes to publish" : "No matching changes",
                        systemImage: all.isEmpty ? "checkmark.circle" : "magnifyingglass",
                        description: Text(all.isEmpty ? "Your draft matches the current theme." : "Try another search or filter. Your other changes are still included."))
                    if !all.isEmpty { Button("Clear filters") { search = ""; category = nil; kind = nil } }
                }
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $search, prompt: "Find an element, setting or wording")
    }
    @ViewBuilder private func counts(_ all: [ThemeChangePresentation]) -> some View {
        ForEach(ThemeDocumentChanges.Kind.allCases, id: \.self) { kind in
            let count = all.filter { $0.change.kind == kind }.count
            if count > 0 { ThemeChangeBadge(kind: kind, count: count) }
        }
    }
    private func filterPill(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.subheadline.weight(selected ? .semibold : .regular))
                .padding(.horizontal, 14).padding(.vertical, 10)
                .foregroundStyle(selected ? Color.accentColor : Color.primary)
                .background(selected ? Color.accentColor.opacity(0.12) : Color(uiColor: .tertiarySystemFill), in: Capsule())
        }
        .buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("ThemeReview.filter." + title)
    }
    private func publicationBar(count: Int, filtered: Int) -> some View {
        VStack(spacing: 8) {
            if filtered != count || !dynamicTypeSize.isAccessibilitySize {
                Text(filtered == count ? "Apps receive the theme on their next refresh." : "All \(count) changes will be published, including filtered results.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            Button {
                reviewedDocument = model.data; publicationCount = count; confirmPublish = true
            } label: {
                HStack(spacing: 8) {
                    if model.busy { ProgressView().tint(.white) }
                    else { Image(systemName: "icloud.and.arrow.up") }
                    Text(model.busy ? "Publishing…" : "Publish \(count) \(count == 1 ? "change" : "changes")")
                        .fontWeight(.semibold).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .disabled(!model.canPublish || count == 0).accessibilityIdentifier("ThemeManagement.publish")
        }.padding().background(Color(uiColor: .systemBackground))
            .overlay(alignment: .top) { Divider() }
    }
    private var success: some View {
        VStack(spacing: 18) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 52)).foregroundStyle(.green).accessibilityHidden(true)
            Text("Your theme is published").font(.title2.bold())
            Text("\(publicationCount) \(publicationCount == 1 ? "change is" : "changes are") now available to apps using \(model.themeID ?? "this theme").")
                .multilineTextAlignment(.center)
            Text("Apps pick up this version on their next refresh. This app is already using it.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Done") { dismiss() }.buttonStyle(.borderedProminent).controlSize(.large)
        }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("ThemeReview.published")
    }
}

private struct ThemeChangeBadge: View {
    let kind: ThemeDocumentChanges.Kind
    var count: Int? = nil
    private var icon: String { switch kind { case .added: return "plus.circle"; case .modified: return "pencil.circle"; case .removed: return "minus.circle" } }
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon).accessibilityHidden(true)
            Text(count.map { "\($0) \(kind.rawValue.lowercased())" } ?? kind.rawValue)
        }
            .font(.caption.weight(.medium)).foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
            .fixedSize()
    }
}

@MainActor
private struct ThemeReviewChangeCard: View {
    let entry: ThemeChangePresentation
    let baseline: Data
    let draft: Data
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.title).font(.headline).foregroundStyle(.primary)
                    if !entry.context.isEmpty { Text(entry.context).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                    if entry.property != "Value", entry.property != entry.title { Text(entry.property).font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 4)
                ThemeChangeBadge(kind: entry.change.kind)
            }
            ThemeReviewComparison(entry: entry, baseline: baseline, draft: draft, compact: true)
        }.padding(.vertical, 8)
    }
}

@MainActor
private struct ThemeReviewComparison: View {
    let entry: ThemeChangePresentation
    let baseline: Data
    let draft: Data
    var compact = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            panel(entry.change.old, other: entry.change.new, before: true)
            panel(entry.change.new, other: entry.change.old, before: false)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func panel(_ value: ThemeDocumentChanges.Value?, other: ThemeDocumentChanges.Value?, before: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(before ? "Before" : "After", systemImage: before ? "arrow.uturn.backward" : "arrow.right")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary).labelStyle(.titleAndIcon)
            HStack(alignment: .top, spacing: 10) {
                if let color = entry.swatch(value, document: before ? baseline : draft) {
                    RoundedRectangle(cornerRadius: 8).fill(color).frame(width: 36, height: 36)
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.2)))
                        .accessibilityHidden(true)
                }
                let displayed = entry.display(value)
                let comparison = entry.display(other)
                let isText = (value?.string != nil || value == nil && entry.defaultText != nil)
                    && (other?.string != nil || other == nil && entry.defaultText != nil)
                Text(isText ? ThemeTextDifference.emphasized(displayed, comparedTo: comparison, removal: before) : AttributedString(displayed))
                    .font(.body).foregroundStyle(.primary).lineLimit(compact ? 3 : nil)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if value == nil, entry.defaultText != nil { Text("App default").font(.caption).foregroundStyle(.secondary) }
            if let value, let children = value.children, !children.isEmpty {
                if compact { Text("Open to compare every item").font(.caption).foregroundStyle(.secondary) }
                else { ThemeReviewValueTree(value: value) }
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(before ? Color(uiColor: .tertiarySystemFill) : Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }
}

/// Expand structured host values as labelled rows. Paging keeps very large lists
/// usable on a phone and always exposes how much remains to inspect.
@MainActor
private struct ThemeReviewValueTree: View {
    let value: ThemeDocumentChanges.Value
    @State private var limit = 50
    private var rows: [(path: String, value: String)] {
        var result: [(String, String)] = []
        func walk(_ value: ThemeDocumentChanges.Value, path: [String]) {
            if let children = value.children, !children.isEmpty {
                for (name, child) in children { walk(child, path: path + [ThemeChangePresentation.readable(name)]) }
            } else { result.append((path.joined(separator: " › "), value.display)) }
        }
        walk(value, path: [])
        return result
    }
    var body: some View {
        let all = rows
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(all.prefix(limit).enumerated()), id: \.offset) { _, row in
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.path).font(.caption).foregroundStyle(.secondary)
                    Text(row.value).font(.callout)
                }
            }
            if all.count > limit { Button("Show more (\(all.count - limit) remaining)") { limit += 50 } }
        }
    }
}

@MainActor
private struct ThemeReviewChangeScreen: View {
    let entry: ThemeChangePresentation
    @ObservedObject var model: ThemeManagementModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        List {
            Section {
                Text(entry.title).font(.title2.bold())
                if !entry.context.isEmpty { Text(entry.context).foregroundStyle(.secondary) }
                ThemeChangeBadge(kind: entry.change.kind)
            }
            Section(entry.property) {
                ThemeReviewComparison(entry: entry, baseline: model.baseline, draft: model.data)
                    .textSelection(.enabled).listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                if entry.unset != "Not set", entry.change.old == nil || entry.change.new == nil {
                    Text(entry.unset == "App default" ? "App default means no text override is set. The app supplies the wording." : "An inherited value uses the existing theme cascade.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section {
                DisclosureGroup("Target details") {
                    LabeledContent("Theme field", value: entry.change.path).font(.caption).textSelection(.enabled)
                    if let selector = entry.change.selector { Text(selector.summary).font(.caption).textSelection(.enabled) }
                }
            }
            Section {
                Button("Discard this change", role: .destructive) {
                    if model.discard(entry.change, title: entry.title) { dismiss() }
                }.disabled(model.busy).accessibilityIdentifier("ThemeReview.discard")
            } footer: { Text("Restores this value from the current theme. Other draft changes stay in place. You can undo from the review.") }
            if let error = model.error { Section { Text(error).foregroundStyle(.red) } }
        }
        .navigationTitle("Change details").navigationBarTitleDisplayMode(.inline)
    }
}
#endif
