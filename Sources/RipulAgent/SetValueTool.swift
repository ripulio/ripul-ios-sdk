import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Set the value of a value-bearing control — date/time pickers, switches,
/// sliders, steppers, segmented controls, picker wheels, text fields.
///
/// The alternative is pretending to operate the control: spinning a date
/// picker's wheels. That cannot be done meaningfully through public API, and
/// simulating it would be an elaborate route to what one property assignment
/// produces exactly — `UIDatePicker.date` plus `.valueChanged` delivers the
/// same value to the same handler a real spin does.
///
/// It also makes a macro readable and durable. "Set addShift.wacInField to
/// 09:00" survives a layout change and says what it means; a recorded gesture
/// over a wheel says nothing and breaks the moment anything moves.
///
/// Surfaced to a remote agent as `device_set_value`.
public struct SetValueTool: NativeTool {
    public let name = "set_value"
    public let description = "Set the value of a value-bearing control instead of trying to operate it: "
        + "date/time pickers, switches, sliders, steppers, segmented controls, picker wheels and text "
        + "fields. Addressed like tap_element (handle > id/text/role/class, optional within). Dates accept "
        + "ISO8601, \"yyyy-MM-dd HH:mm\", \"yyyy-MM-dd\" or \"HH:mm\" (bare times mean today). Switches take "
        + "on/off. Segmented controls take an index or a segment title. Fires .valueChanged, so the app's "
        + "handler runs exactly as it would for a real interaction. Searches at or below the matched "
        + "element, then its enclosing SwiftUI island."
    public let inputSchema: [String: Any] = ToolSchema.object(
        .string("value", "The value to set — a date/time, on/off, a number, a segment title or index, or text"),
        .string("handle", "Handle from the last inspect_screen (preferred, exact)"),
        .string("id", "Accessibility id / uiKitIdentifier of the element (exact)"),
        .string("text", "Visible text to match (case-insensitive substring)"),
        .string("role", "Element role (see inspect_screen's role field)"),
        .string("class", "Class-name substring, e.g. \"DatePicker\""),
        .number("nth", "0-based ordinal when several disjoint elements match (last resort)")
    )

    public init() {}

    public func execute(args: [String: Any]) async throws -> Any {
        #if canImport(UIKit)
        guard let value = args["value"] as? String else {
            return ["success": false, "error": "value is required"]
        }
        return await MainActor.run { () -> Any in
            let target: ScreenElementFinder.Match
            let matchCount: Int
            switch ScreenElementFinder.resolveTarget(args: args) {
            case .failure(let error): return error
            case .target(let m, let count): target = m; matchCount = count
            }
            let outcome = ScreenActuationEngine.performSetValue(on: target.view, value: value)
            var result: [String: Any] = ["success": outcome.success,
                                         "matched": matchCount,
                                         "element": ScreenElementFinder.describe(target),
                                         "trace": outcome.trace]
            if let via = outcome.via { result["via"] = via }
            if let set = outcome.activatedLabel { result["set"] = set }
            if let error = outcome.error { result["error"] = error }
            return result
        }
        #else
        return ["success": false, "error": "set_value requires UIKit"]
        #endif
    }
}
