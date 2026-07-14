import Foundation

/// Swift twin of `parameterKinds.ts` — parameter kinds own the value shape
/// and the projections (pure folds from value → query bind params). The same
/// projection runs for every query reading the parameter, so the fold lives
/// in exactly one place.
///
/// Values are kept as open `CmsJSON` objects (matching the web's JSON store):
///  - datePredicate: `{ operator, start, end }`
///  - value:         `{ value, values, type }`
public enum CmsParameterProjection {
    /// One bind param.
    case single(CmsJSON)
    /// A half-open `[from, to)` range — the param plus its `toParam` companion.
    case range(from: CmsJSON, to: CmsJSON)
    /// Not ready — the query should wait.
    case waiting(String)
}

public enum CmsParameterKinds {
    /// Twin of `TypedParam` single-mode: `{ value, type }`.
    static func typedParam(_ value: String?, type: String) -> CmsJSON {
        .object(["value": value.map { .string($0) } ?? .null, "type": .string(type)])
    }

    /// Twin of `TypedParam` multi-mode: `{ values, type, mode: 'multi' }`.
    static func typedMultiParam(_ values: [String], type: String) -> CmsJSON {
        .object([
            "values": .array(values.map { .string($0) }),
            "type": .string(type),
            "mode": .string("multi"),
        ])
    }

    public static func defaultValue(kind: String) -> CmsJSON {
        switch kind {
        case "datePredicate":
            return .object(["operator": .string("gte"), "start": .null, "end": .null])
        case "value":
            return .object(["value": .null, "values": .null])
        default:
            return .null
        }
    }

    /// Apply `kind/projection` to a parameter value. Mirrors the web's
    /// projection tables including their waiting semantics.
    public static func project(kind: String, projection: String, value: CmsJSON) -> CmsParameterProjection {
        let obj = value.objectValue ?? [:]
        switch (kind, projection) {

        // ── datePredicate ────────────────────────────────────────────────
        case ("datePredicate", "range"):
            let op = obj.string("operator").flatMap(CmsRangePredicateOperator.init(rawValue:)) ?? .gte
            if op == .any || op.isPeriod {
                let b = CmsDatePredicate.boundsForRange(op, start: CmsDatePredicate.dateMin)
                return .range(from: typedParam(b.from, type: "date"), to: typedParam(b.to, type: "date"))
            }
            guard let start = obj.string("start"), !start.isEmpty else {
                return .waiting("waiting for a date pick")
            }
            let b = CmsDatePredicate.boundsForRange(op, start: start, end: obj.string("end"))
            return .range(from: typedParam(b.from, type: "date"), to: typedParam(b.to, type: "date"))

        case ("datePredicate", "operator"):
            let op = obj.string("operator") ?? "gte"
            return .single(typedParam(op, type: "string"))

        case ("datePredicate", "date"):
            guard let start = obj.string("start"), !start.isEmpty else {
                return .waiting("waiting for a date pick")
            }
            return .single(typedParam(start, type: "date"))

        // ── value ────────────────────────────────────────────────────────
        case ("value", "single"):
            guard let v = obj.string("value"), !v.isEmpty else {
                return .waiting("value parameter unset")
            }
            return .single(typedParam(v, type: obj.string("type") ?? "string"))

        case ("value", "list"):
            let values = obj["values"]?.arrayValue?.compactMap { $0.stringValue } ?? []
            return .single(typedMultiParam(values, type: obj.string("type") ?? "string"))

        default:
            return .waiting("unknown parameter kind/projection \"\(kind)/\(projection)\" — binding broken")
        }
    }
}

extension CmsJSON {
    var arrayValue: [CmsJSON]? {
        if case .array(let a) = self { return a }
        return nil
    }
}
