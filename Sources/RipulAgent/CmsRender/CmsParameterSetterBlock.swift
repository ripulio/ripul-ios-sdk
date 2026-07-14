import SwiftUI

/// Native twin of the web `parameterSetter` block (ParameterBlock.tsx).
/// Headless at runtime: enforces a constant value into a shared Parameter so
/// queries bound to it resolve (e.g. an `all_employees` flag a shifts query
/// reads). Invisible — its whole job is the write.
struct CmsParameterSetterBlockView: View {
    let block: CmsBlock
    @EnvironmentObject var runtime: CmsRuntime

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear { writeParameter() }
    }

    /// Twin of the web's `nextValue` memo — the typed value in the shape the
    /// matching ParameterKind expects. The runtime's setParameter is a plain
    /// store write; publishing an identical value is cheap and re-triggers
    /// nothing downstream (param hashes dedupe the refetch).
    private func writeParameter() {
        let parameterId = (block.props.string("parameterId") ?? "").trimmingCharacters(in: .whitespaces)
        guard !parameterId.isEmpty else { return }

        let value: CmsJSON
        if (block.props.string("kind") ?? "datePredicate") == "value" {
            let parts = (block.props.string("value") ?? "")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            value = .object([
                "value": parts.first.map { .string($0) } ?? .null,
                "values": parts.isEmpty ? .null : .array(parts.map { .string($0) }),
                "type": .string(block.props.string("valueType") ?? "string"),
            ])
        } else {
            let op = block.props.string("operator") ?? "any"
            let start = block.props.string("startDate") ?? ""
            let end = block.props.string("endDate") ?? ""
            value = .object([
                "operator": .string(op),
                "start": (op == "any" || start.isEmpty) ? .null : .string(start),
                "end": (op == "between" && !end.isEmpty) ? .string(end) : .null,
            ])
        }
        if runtime.parameters[parameterId] == value { return }
        runtime.setParameter(parameterId, value: value)
    }
}
