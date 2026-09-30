import Foundation

/// Presentation data only. Tool values, permissions and answer delivery stay with the web owner.
struct NativeInteractionSnapshot: Decodable {
  struct Option: Decodable { let index: Int; let label: String; let description: String }
  struct Tab: Decodable { let title: String; let content: String }
  struct Row: Decodable { let cells: [String]; let optionIndex: Int; let link: String }
  struct DateInput: Decodable {
    let includeTime: Bool?
    let minDate: String?
    let maxDate: String?
    let defaultDate: String?
  }
  let question: String
  let severity: String
  let options: [Option]
  let multiSelect: Bool
  let expectsResponse: Bool
  let selectedIndices: [Int]
  let dateInput: DateInput?
  let selectedDate: String
  let text: String
  let editSequence: Int
  let disabled: Bool
  let completed: Bool
  let busy: Bool
  let error: String
  let answer: String
  let tabs: [Tab]
  let headers: [String]
  let rows: [Row]

  static func decode(_ value: [String: Any]) throws -> Self {
    let snapshot = try JSONDecoder().decode(Self.self, from: JSONSerialization.data(withJSONObject: value))
    guard snapshot.editSequence >= 0,
      snapshot.options.enumerated().allSatisfy({ $0.offset == $0.element.index }),
      snapshot.selectedIndices.allSatisfy({ snapshot.options.indices.contains($0) }),
      Set(snapshot.selectedIndices).count == snapshot.selectedIndices.count,
      snapshot.rows.allSatisfy({ $0.cells.count == snapshot.headers.count &&
        ($0.optionIndex == -1 || snapshot.options.indices.contains($0.optionIndex)) })
    else { throw CocoaError(.coderInvalidValue) }
    return snapshot
  }

  /// Match HTML date/datetime-local values without UTC day shifts.
  static func date(_ value: String, includeTime: Bool) -> Date? {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.dateFormat = includeTime ? "yyyy-MM-dd'T'HH:mm" : "yyyy-MM-dd"
    formatter.isLenient = false
    guard let date = formatter.date(from: value), formatter.string(from: date) == value else { return nil }
    return date
  }
  static func dateString(_ value: Date, includeTime: Bool) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.dateFormat = includeTime ? "yyyy-MM-dd'T'HH:mm" : "yyyy-MM-dd"
    return formatter.string(from: value)
  }
  var dateRange: ClosedRange<Date> {
    func bound(_ value: String?, end: Bool) -> Date? {
      guard let value else { return nil }
      if let date = Self.date(value, includeTime: true) { return date }
      guard let date = Self.date(value, includeTime: false) else { return nil }
      if end && dateInput?.includeTime == true {
        return Calendar(identifier: .gregorian).date(byAdding: .day, value: 1, to: date)?.addingTimeInterval(-60)
      }
      return date
    }
    let lower = bound(dateInput?.minDate, end: false) ?? .distantPast
    let upper = bound(dateInput?.maxDate, end: true) ?? .distantFuture
    return lower...max(lower, upper)
  }
}
