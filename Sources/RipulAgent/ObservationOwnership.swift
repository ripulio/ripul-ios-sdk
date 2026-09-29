import SwiftUI
import Combine

/// Owns a model object for a view's lifetime, created exactly once, without
/// subscribing the view to it.
///
/// For an `@Observable` model, `@State private var model = Model(...)` would
/// evaluate the initializer every time the owning view's struct is rebuilt —
/// a throwaway model (with its subscriptions and loads) per parent re-render.
/// `@StateObject` takes an autoclosure and keeps the first instance, and this
/// box publishes nothing, so ownership costs no re-renders. Views that read
/// the model's properties are tracked by Observation as usual.
public final class UnobservedOwner<Value: AnyObject>: ObservableObject {
    public let value: Value
    public init(_ value: Value) { self.value = value }
}

/// Evaluates `content` in its own view, so the reads it makes of an
/// `@Observable` model re-render only this view, not its parent.
public struct ObservedModel<Model: AnyObject, Content: View>: View {
    private let model: Model
    private let content: (Model) -> Content
    public init(_ model: Model, @ViewBuilder content: @escaping (Model) -> Content) {
        self.model = model
        self.content = content
    }
    public var body: some View { content(model) }
}

/// A Combine stream for one `@Observable` property: the `$property` publisher
/// `@Published` used to provide. Send from the property's `didSet`; the
/// subject is created on first subscription, seeded with the current value.
final class PropertyStream<Value> {
    private var subject: CurrentValueSubject<Value, Never>?
    func publisher(current: @autoclosure () -> Value) -> AnyPublisher<Value, Never> {
        if let subject { return subject.eraseToAnyPublisher() }
        let subject = CurrentValueSubject<Value, Never>(current())
        self.subject = subject
        return subject.eraseToAnyPublisher()
    }
    func send(_ value: Value) { subject?.send(value) }
}
