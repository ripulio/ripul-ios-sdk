#if os(iOS)
import UIKit

private var nativeLabelStateKey: UInt8 = 0

@MainActor
enum NativeLabelTheme {
    enum Value {
        case plain(String?)
        case attributed(NSAttributedString?)
        var text: String { switch self { case .plain(let value): return value ?? ""; case .attributed(let value): return value?.string ?? "" } }
        var isUniform: Bool {
            guard case .attributed(let value) = self, let value, value.length > 0 else { return true }
            let first = value.attributes(at: 0, effectiveRange: nil) as NSDictionary
            var uniform = true
            value.enumerateAttributes(in: NSRange(location: 0, length: value.length)) { attributes, _, stop in
                if !first.isEqual(to: attributes) { uniform = false; stop.pointee = true }
            }
            return uniform
        }
        func write(to label: UILabel, replacing text: String? = nil) {
            switch self {
            case .plain(let original):
                let output = text ?? original
                if label.text != output { label.text = output }
            case .attributed(let original):
                if let text {
                    let attributes = original.flatMap { $0.length > 0 ? $0.attributes(at: 0, effectiveRange: nil) : nil } ?? [:]
                    let output = NSAttributedString(string: text, attributes: attributes)
                    if label.attributedText != output { label.attributedText = output }
                } else if label.attributedText != original { label.attributedText = original }
            }
        }
    }
    private final class State {
        var appValue: Value
        var writing = false
        var applied = false
        init(_ label: UILabel) {
            appValue = label.attributedText.map { .attributed($0.copy() as? NSAttributedString) } ?? .plain(label.text)
        }
    }
    private static var installed = false
    private static let labels = NSHashTable<UILabel>.weakObjects()
    private static var previews: [String: NativeLabelOverride] = [:]
    private static var discovered: [String: NativeLabelSelector] = [:]
    private static var queued = false
    private static var refreshing = false

    static func install() {
        guard !installed else { return }; installed = true
        NativeTextHooks.intercept(UILabel.self, #selector(setter: UILabel.text), #selector(UILabel.ripul_setThemeText(_:)))
        NativeTextHooks.intercept(UILabel.self, #selector(setter: UILabel.attributedText), #selector(UILabel.ripul_setThemeAttributedText(_:)))
        NativeTextHooks.intercept(UILabel.self, #selector(setter: UILabel.accessibilityIdentifier), #selector(UILabel.ripul_setThemeLabelIdentifier(_:)))
        NativeTextHooks.intercept(UILabel.self, #selector(UILabel.didMoveToWindow), #selector(UILabel.ripul_themeLabelMovedToWindow))
        NativeTextHooks.intercept(UILabel.self, #selector(UILabel.didMoveToSuperview), #selector(UILabel.ripul_themeLabelMovedToSuperview))
        NativeTextHooks.intercept(UITableViewCell.self, #selector(UITableViewCell.prepareForReuse), #selector(UITableViewCell.ripul_themePrepareForReuse))
        NativeTextHooks.intercept(UICollectionViewCell.self, #selector(UICollectionViewCell.prepareForReuse), #selector(UICollectionViewCell.ripul_themePrepareForReuse))
        refresh(discover: !NativeTextRuntime.current.labels.isEmpty)
    }

    private static func existing(_ label: UILabel) -> State? { objc_getAssociatedObject(label, &nativeLabelStateKey) as? State }
    private static func state(_ label: UILabel) -> State {
        if let record = existing(label) { return record }
        let record = State(label)
        objc_setAssociatedObject(label, &nativeLabelStateKey, record, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        labels.add(label)
        return record
    }
    private static var rules: [NativeLabelOverride] {
        var combined = Dictionary(uniqueKeysWithValues: NativeTextRuntime.current.labels.map { ($0.id, $0) })
        combined.merge(previews) { _, trial in trial }
        return Array(combined.values)
    }
    private static func potentiallyMatches(_ label: UILabel, selectors: [NativeLabelSelector]) -> Bool {
        guard !selectors.isEmpty, NativeLabelIdentity.allowed(label) else { return false }
        if selectors.contains(where: { $0.identifier != nil && $0.identifier == label.accessibilityIdentifier }) { return true }
        let ownerTypes = Set(selectors.compactMap(\.ownerType))
        return NativeLabelIdentity.owners(of: label).contains { ownerTypes.contains(String(describing: type(of: $0))) }
    }

    static func assigned(_ value: Value, to label: UILabel, forward: () -> Void) {
        if existing(label)?.writing == true { forward(); return }
        guard existing(label) != nil || potentiallyMatches(label, selectors: rules.map(\.selector)) else { forward(); return }
        let record = state(label)
        record.appValue = value
        record.writing = true; forward(); record.writing = false
        guard record.applied || potentiallyMatches(label, selectors: rules.map(\.selector)) else { return }
        refresh()
        scheduleRefresh() // catches text-before-model configuration in the same run loop
    }
    static func movedOrIdentified(_ label: UILabel) {
        guard existing(label)?.writing != true,
              existing(label) != nil || potentiallyMatches(label, selectors: rules.map(\.selector)) else { return }
        _ = state(label)
        refresh(); scheduleRefresh()
    }
    static func prepareForReuse(_ cell: UIView) {
        for label in labels.allObjects where label.isDescendant(of: cell) {
            guard let record = existing(label), record.applied else { continue }
            record.writing = true; record.appValue.write(to: label); record.writing = false
            record.applied = false
        }
        scheduleRefresh()
    }
    private static func scheduleRefresh() {
        guard !queued else { return }; queued = true
        DispatchQueue.main.async {
            queued = false
            refresh()
        }
    }

    private static func walkLabels(_ visit: (UILabel) -> Void) {
        func walk(_ view: UIView) {
            if let label = view as? UILabel { visit(label) }
            for child in view.subviews { walk(child) }
        }
        var windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        if windows.isEmpty { windows = UIApplication.shared.windows }
        windows += labels.allObjects.compactMap(\.window)
        var visited = Set<ObjectIdentifier>()
        for window in windows where !RipulChrome.isRipulWindow(window) && visited.insert(ObjectIdentifier(window)).inserted { walk(window) }
    }
    private static func discoverMatches(_ selectors: [NativeLabelSelector]) {
        guard !selectors.isEmpty else { return }
        walkLabels { label in if potentiallyMatches(label, selectors: selectors) { _ = state(label) } }
    }

    static func refresh(discover: Bool = false) {
        guard !refreshing else { scheduleRefresh(); return }
        refreshing = true; defer { refreshing = false }
        let active = rules
        if discover { discoverMatches(active.map(\.selector)) }
        let live = labels.allObjects
        // Match in each screen instance. Multiple windows may render the same
        // semantic label, but two matches in one screen require a better identity.
        var matches: [ObjectIdentifier: [NativeLabelOverride]] = [:]
        var counts: [ObjectIdentifier: [String: Int]] = [:]
        for label in live where label.window != nil {
            guard let controller = NativeLabelIdentity.screen(of: label) else { continue }
            let matching = active.filter { NativeLabelIdentity.matches($0.selector, label: label) }
            matches[ObjectIdentifier(label)] = matching
            for rule in matching { counts[ObjectIdentifier(controller), default: [:]][rule.id, default: 0] += 1 }
        }
        for label in live {
            let record = state(label)
            guard !record.writing else { continue }
            let matching = matches[ObjectIdentifier(label)] ?? []
            let controller = NativeLabelIdentity.screen(of: label).map(ObjectIdentifier.init)
            let rule = matching.count == 1 ? matching.first : nil
            let replacement: String?
            if let rule, let controller, counts[controller]?[rule.id] == 1, record.appValue.isUniform { replacement = rule.text }
            else { replacement = nil }
            if replacement != nil || record.applied {
                record.writing = true
                record.appValue.write(to: label, replacing: replacement)
                record.writing = false
            }
            record.applied = replacement != nil
        }
    }

    static func capture(_ label: UILabel) -> NativeLabelIdentity.Capture {
        guard NativeLabelIdentity.allowed(label) else { return NativeLabelIdentity.capture(label) }
        let record = state(label)
        guard record.appValue.isUniform else {
            return .init(reason: "This label mixes text styles. It needs a component adapter to preserve those runs.")
        }
        let capture = NativeLabelIdentity.capture(label)
        if let selector = capture.selector {
            discovered[selector.id] = selector
            discoverMatches([selector])
            let candidates = labels.allObjects.filter {
                $0.window != nil && NativeLabelIdentity.screen(of: $0) === NativeLabelIdentity.screen(of: label) && NativeLabelIdentity.matches(selector, label: $0)
            }
            if candidates.count > 1 { return .init(reason: "More than one label matches this target. Use a more specific row identity or the app-wide context hook.") }
        }
        return capture
    }

    static func discoverEditableLabels() {
        walkLabels { label in
            guard NativeLabelIdentity.allowed(label), !(label.text ?? "").isEmpty,
                  let selector = NativeLabelIdentity.capture(label).selector else { return }
            let record = state(label)
            guard record.appValue.isUniform else { return }
            discovered[selector.id] = selector
        }
    }
    struct Element: Identifiable {
        let selector: NativeLabelSelector
        let text: String
        let mounted: Bool
        let ambiguous: Bool
        var id: String { selector.id }
    }
    static var elements: [Element] {
        var all = discovered
        for rule in NativeTextRuntime.current.labels { all[rule.id] = rule.selector }
        return all.values.map { selector in
            let matching = labels.allObjects.filter { $0.window != nil && NativeLabelIdentity.matches(selector, label: $0) }
            let grouped = Dictionary(grouping: matching, by: { NativeLabelIdentity.screen(of: $0).map(ObjectIdentifier.init) })
            return Element(selector: selector,
                           text: NativeTextRuntime.current.labels.first { $0.id == selector.id }?.text ?? matching.first?.text ?? "",
                           mounted: !matching.isEmpty, ambiguous: grouped.values.contains { $0.count > 1 })
        }.sorted { $0.selector.summary < $1.selector.summary }
    }
    static func appText(_ selector: NativeLabelSelector) -> String? {
        labels.allObjects.first { NativeLabelIdentity.matches(selector, label: $0) }.flatMap { existing($0)?.appValue.text }
    }
    static func preview(_ selector: NativeLabelSelector, text: String?) {
        previews[selector.id] = text.map { NativeLabelOverride(selector: selector, text: $0) }
        discoverMatches([selector]); refresh()
    }
    static func setOverride(_ selector: NativeLabelSelector, text: String?) {
        previews.removeValue(forKey: selector.id)
        NativeTextRuntime.mutate { $0.setLabel(selector, text: text) }
    }
    static func clearPreviews() { previews.removeAll() }
}

extension UILabel {
    @objc fileprivate func ripul_setThemeText(_ text: String?) {
        NativeLabelTheme.assigned(.plain(text), to: self) { ripul_setThemeText(text) }
    }
    @objc fileprivate func ripul_setThemeAttributedText(_ text: NSAttributedString?) {
        NativeLabelTheme.assigned(.attributed(text?.copy() as? NSAttributedString), to: self) { ripul_setThemeAttributedText(text) }
    }
    @objc fileprivate func ripul_setThemeLabelIdentifier(_ identifier: String?) {
        ripul_setThemeLabelIdentifier(identifier); NativeLabelTheme.movedOrIdentified(self)
    }
    @objc fileprivate func ripul_themeLabelMovedToWindow() {
        ripul_themeLabelMovedToWindow(); NativeLabelTheme.movedOrIdentified(self)
    }
    @objc fileprivate func ripul_themeLabelMovedToSuperview() {
        ripul_themeLabelMovedToSuperview(); NativeLabelTheme.movedOrIdentified(self)
    }
}
extension UITableViewCell {
    @objc fileprivate func ripul_themePrepareForReuse() { NativeLabelTheme.prepareForReuse(self); ripul_themePrepareForReuse() }
}
extension UICollectionViewCell {
    @objc fileprivate func ripul_themePrepareForReuse() { NativeLabelTheme.prepareForReuse(self); ripul_themePrepareForReuse() }
}
#endif
