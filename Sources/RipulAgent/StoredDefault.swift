import SwiftUI
import Observation

/// A drop-in for `@AppStorage` that re-renders a view only when *its own key*
/// changes.
///
/// `@AppStorage` re-evaluates its view on writes to the store it watches, and
/// a key that has never been set reports "changed" every time. The app writes
/// UserDefaults continuously during normal use (read markers, caches, window
/// selection), so every large view carrying `@AppStorage` re-ran its whole body
/// on unrelated writes — measured on iPhone as the shell re-rendering about
/// once a second mid-swipe.
///
/// Backed by one shared `@Observable` box per (store, key): the box re-reads
/// its key on `UserDefaults.didChangeNotification` and assigns only when the
/// value differs, so Observation invalidates exactly the views that read it.
/// Same declaration shape as `@AppStorage`, including `$value` bindings and
/// `_value = StoredDefault(wrappedValue:_:store:)` in an initializer.
@MainActor
@propertyWrapper
public struct StoredDefault<Value: Equatable> {
    private let box: StoredDefaultBox<Value>

    public var wrappedValue: Value {
        get { box.value }
        nonmutating set { box.write(newValue) }
    }

    public var projectedValue: Binding<Value> {
        let box = self.box
        return Binding(get: { box.value }, set: { box.write($0) })
    }

    private init(key: String, store: UserDefaults?, read: @escaping (UserDefaults) -> Value,
                 write: @escaping (UserDefaults, Value) -> Void) {
        box = StoredDefaultBox.shared(key: key, store: store ?? .standard, read: read, write: write)
    }
}

public extension StoredDefault where Value == Bool {
    init(wrappedValue: Bool, _ key: String, store: UserDefaults? = nil) {
        self.init(key: key, store: store,
                  read: { $0.object(forKey: key) as? Bool ?? wrappedValue },
                  write: { $0.set($1, forKey: key) })
    }
}

public extension StoredDefault where Value == String {
    init(wrappedValue: String, _ key: String, store: UserDefaults? = nil) {
        self.init(key: key, store: store,
                  read: { $0.string(forKey: key) ?? wrappedValue },
                  write: { $0.set($1, forKey: key) })
    }
}

public extension StoredDefault where Value == Int {
    init(wrappedValue: Int, _ key: String, store: UserDefaults? = nil) {
        self.init(key: key, store: store,
                  read: { $0.object(forKey: key) as? Int ?? wrappedValue },
                  write: { $0.set($1, forKey: key) })
    }
}

public extension StoredDefault where Value == Double {
    init(wrappedValue: Double, _ key: String, store: UserDefaults? = nil) {
        self.init(key: key, store: store,
                  read: { $0.object(forKey: key) as? Double ?? wrappedValue },
                  write: { $0.set($1, forKey: key) })
    }
}

public extension StoredDefault where Value: RawRepresentable, Value.RawValue == String {
    init(wrappedValue: Value, _ key: String, store: UserDefaults? = nil) {
        self.init(key: key, store: store,
                  read: { $0.string(forKey: key).flatMap(Value.init(rawValue:)) ?? wrappedValue },
                  write: { $0.set($1.rawValue, forKey: key) })
    }
}

/// One observable value per (store, key), shared by every view that reads it.
@MainActor
@Observable
final class StoredDefaultBox<Value: Equatable> {
    private(set) var value: Value
    @ObservationIgnored private let store: UserDefaults
    @ObservationIgnored private let read: (UserDefaults) -> Value
    @ObservationIgnored private let writeValue: (UserDefaults, Value) -> Void
    @ObservationIgnored private var observer: NSObjectProtocol?

    private init(store: UserDefaults, read: @escaping (UserDefaults) -> Value,
                 write: @escaping (UserDefaults, Value) -> Void) {
        self.store = store
        self.read = read
        self.writeValue = write
        self.value = read(store)
        // Suites can post from other UserDefaults instances for the same
        // domain, so listen to all and re-read this one key.
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func write(_ newValue: Value) {
        writeValue(store, newValue)
        if value != newValue { value = newValue }
    }

    private func refresh() {
        let current = read(store)
        if current != value { value = current }
    }

    private static var boxes: [String: AnyObject] { get { registry } set { registry = newValue } }

    static func shared(key: String, store: UserDefaults, read: @escaping (UserDefaults) -> Value,
                       write: @escaping (UserDefaults, Value) -> Void) -> StoredDefaultBox<Value> {
        let id = "\(ObjectIdentifier(store).hashValue)|\(key)|\(Value.self)"
        if let box = boxes[id] as? StoredDefaultBox<Value> { return box }
        let box = StoredDefaultBox(store: store, read: read, write: write)
        boxes[id] = box
        return box
    }
}

/// Type-erased registry backing `StoredDefaultBox.shared` (generic types can't
/// hold static stored properties).
@MainActor private var registry: [String: AnyObject] = [:]
