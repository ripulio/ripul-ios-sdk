import Foundation
import SwiftUI

public indirect enum NativeArtefactValue: Decodable, Equatable {
  case text(String)
  case number(Double)
  case boolean(Bool)
  case array([NativeArtefactValue])
  case object([String: NativeArtefactValue])
  case null
  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode([NativeArtefactValue].self) {
      self = .array(value)
    } else if let value = try? container.decode([String: NativeArtefactValue].self) {
      self = .object(value)
    } else if let value = try? container.decode(Bool.self) {
      self = .boolean(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else {
      self = .text(try container.decode(String.self))
    }
  }
  public var json: Any {
    switch self {
    case .text(let value): value
    case .number(let value): value
    case .boolean(let value): value
    case .array(let value): value.map { $0.json }
    case .object(let value): value.mapValues { $0.json }
    case .null: NSNull()
    }
  }
  public var inputText: String {
    switch self {
    case .text(let value): value
    case .boolean(let value): value ? "true" : "false"
    case .array, .object, .null:
      String(
        data: (try? JSONSerialization.data(
          withJSONObject: json, options: [.fragmentsAllowed, .sortedKeys])) ?? Data(),
        encoding: .utf8) ?? ""
    case .number(let value):
      String(value).replacingOccurrences(of: ".", with: Locale.current.decimalSeparator ?? ".")
    }
  }
  public func formatted(as field: NativeArtefactOutputField) -> String {
    switch self {
    case .text(let value): return value
    case .array, .object, .null: return inputText
    case .boolean(let value): return value ? "Yes" : "No"
    case .number(let value):
      if field.format == "currency", let currency = field.currency {
        return value.formatted(.currency(code: currency))
      }
      if field.format == "percent" {
        return value.formatted(.percent.precision(.fractionLength(0...2)))
      }
      return value.formatted(.number.precision(.fractionLength(0...6)))
    }
  }
}
public struct NativeArtefactInputField: Decodable, Identifiable {
  public let key: String
  public let type: String
  public let label: String
  public let defaultValue: NativeArtefactValue
  public let minimum: Double?
  public let maximum: Double?
  public let maxLength: Int?
  public var id: String { key }
  enum CodingKeys: String, CodingKey {
    case key, type, label
    case defaultValue = "default"
    case minimum, maximum, maxLength
  }
}
public struct NativeArtefactOutputField: Decodable, Identifiable {
  public let key: String
  public let type: String
  public let label: String
  public let format: String?
  public let currency: String?
  public var id: String { key }
}

/// Shared definition-driven controls for the native library and embedded chat.
public struct NativeArtefactFields: View {
  let fields: [NativeArtefactInputField]
  let values: [String: String]
  let focus: FocusState<String?>.Binding
  let onChange: (String, String) -> Void
  public init(
    fields: [NativeArtefactInputField], values: [String: String],
    focus: FocusState<String?>.Binding,
    onChange: @escaping (String, String) -> Void
  ) {
    self.fields = fields
    self.values = values
    self.focus = focus
    self.onChange = onChange
  }
  public var body: some View {
    ForEach(fields) { field in
      if field.type == "boolean" {
        Toggle(
          field.label,
          isOn: Binding(
            get: { values[field.key] == "true" },
            set: { onChange(field.key, $0 ? "true" : "false") })
        )
        .uiKitIdentifier("Artefacts.input.\(field.key)")
      } else {
        LabeledContent(field.label) {
          TextField(
            field.label,
            text: Binding(get: { values[field.key] ?? "" }, set: { onChange(field.key, $0) }),
            axis: field.type == "string" ? .vertical : .horizontal
          )
          #if os(iOS)
            .keyboardType(field.type == "string" ? .default : .numbersAndPunctuation)
          #endif
          .multilineTextAlignment(.trailing).focused(focus, equals: field.key)
          .uiKitIdentifier("Artefacts.input.\(field.key)")
        }
      }
    }
  }
}

public struct NativeArtefactResultRow: View {
  let label: String
  let value: String
  public init(label: String, value: String) {
    self.label = label
    self.value = value
  }
  public var body: some View {
    LabeledContent(label, value: value)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(label).accessibilityValue(value)
  }
}
