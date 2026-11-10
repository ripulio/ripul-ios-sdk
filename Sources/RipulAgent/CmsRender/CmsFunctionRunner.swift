import CmsQuickJS
import Foundation

public struct CmsFunctionError: Error, Equatable {
    public var message: String
    public init(_ message: String) { self.message = message }
}

public struct CmsFunctionTestCaseResult: Equatable {
    public var name: String
    public var pass: Bool
    public var expected: CmsJSON
    public var actual: CmsJSON?
    public var error: String?
}

public struct CmsFunctionTestSuiteResult: Equatable {
    public var passed: Bool
    public var results: [CmsFunctionTestCaseResult]
}

/// Bounded LRU cache for evaluated `fn.<slug>(...)` calls in a record form.
public final class CmsFunctionResultCache {
    private let lock = NSLock()
    private var entries: [String: CmsFormEvalState] = [:]
    private var order: [String] = []
    private let maxEntries: Int

    public init(maxEntries: Int = 256) {
        self.maxEntries = maxEntries
    }

    public func get(_ key: String) -> CmsFormEvalState? {
        lock.lock()
        defer { lock.unlock() }
        guard let value = entries[key] else { return nil }
        if let idx = order.firstIndex(of: key) {
            order.remove(at: idx)
        }
        order.append(key)
        return value
    }

    public func set(_ key: String, _ value: CmsFormEvalState) {
        lock.lock()
        defer { lock.unlock() }
        if entries[key] != nil, let idx = order.firstIndex(of: key) {
            order.remove(at: idx)
        } else if entries.count >= maxEntries, let oldest = order.first {
            order.removeFirst()
            entries.removeValue(forKey: oldest)
        }
        entries[key] = value
        order.append(key)
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
        order.removeAll()
    }
}

private actor CmsFunctionWorkerActor {
    static let shared = CmsFunctionWorkerActor()

    func run(_ fn: CmsFunctionDef, namedInputs: [String: CmsJSON]) -> Result<CmsJSON, CmsFunctionError> {
        CmsFunctionRunner.evaluateRawSync(fn, namedInputs: namedInputs)
    }
}

public enum CmsFunctionRunner {
    public static let maxSourceBytes = 64 * 1024
    public static let maxOutputBytes = 8 * 1024
    private static let validInputTypes: Set<String> = ["number", "string", "boolean", "json"]
    private static let validResultTypes: Set<String> = ["number", "string", "boolean"]

    private static func isValidIdentifier(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 64, let first = s.first, first.isLetter || first == "_" else {
            return false
        }
        return s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    public static func validateDefinition(_ fn: CmsFunctionDef) -> String? {
        let slug = fn.slug.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidIdentifier(slug) else {
            return "Function slug \"\(slug)\" must start with a letter or underscore and contain only letters, digits, or underscores (up to 64 chars)."
        }
        if slug == "fn" {
            return "Function slug cannot be \"fn\"."
        }
        if fn.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Function \"\(slug)\" requires a name."
        }
        var seenInputs = Set<String>()
        for inp in fn.inputs {
            let inName = inp.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isValidIdentifier(inName) else {
                return "Function \"\(slug)\" input name \"\(inName)\" must start with a letter or underscore and contain only letters, digits, or underscores."
            }
            if !seenInputs.insert(inName).inserted {
                return "Function \"\(slug)\" has duplicate input \"\(inName)\"."
            }
            if !validInputTypes.contains(inp.type) {
                return "Function \"\(slug)\" input \"\(inName)\" has unsupported type \"\(inp.type)\"."
            }
        }
        if !validResultTypes.contains(fn.resultType) {
            return "Function \"\(slug)\" has unsupported resultType \"\(fn.resultType)\"."
        }
        if fn.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Function \"\(slug)\" requires non-empty JavaScript code."
        }
        if fn.code.utf8.count > maxSourceBytes {
            return "Function \"\(slug)\" code exceeds the \(maxSourceBytes)-byte limit."
        }
        return nil
    }

    private static func coerceAndValidateInput(_ spec: CmsFunctionInputDef, raw: CmsJSON?) -> Result<CmsJSON, CmsFunctionError> {
        guard let raw, raw != .null else {
            return .success(.null)
        }
        switch spec.type {
        case "number":
            switch raw {
            case .number(let n):
                guard n.isFinite else { return .failure(CmsFunctionError("Input \"\(spec.name)\" must be a finite number.")) }
                return .success(.number(n))
            case .bool(let b):
                return .success(.number(b ? 1 : 0))
            case .string(let s):
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { return .success(.null) }
                guard let n = Double(trimmed), n.isFinite else {
                    return .failure(CmsFunctionError("Input \"\(spec.name)\" must be a number."))
                }
                return .success(.number(n))
            default:
                return .failure(CmsFunctionError("Input \"\(spec.name)\" must be a number."))
            }
        case "string":
            switch raw {
            case .string(let s): return .success(.string(s))
            case .number(let n): return .success(.string(CmsActionForm.numberString(n)))
            case .bool(let b): return .success(.string(b ? "true" : "false"))
            default: return .failure(CmsFunctionError("Input \"\(spec.name)\" must be a string."))
            }
        case "boolean":
            switch raw {
            case .bool(let b): return .success(.bool(b))
            case .number(let n):
                if n == 1 { return .success(.bool(true)) }
                if n == 0 { return .success(.bool(false)) }
                return .failure(CmsFunctionError("Input \"\(spec.name)\" must be a boolean."))
            case .string(let s):
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { return .success(.null) }
                if trimmed == "1" || trimmed == "true" { return .success(.bool(true)) }
                if trimmed == "0" || trimmed == "false" { return .success(.bool(false)) }
                return .failure(CmsFunctionError("Input \"\(spec.name)\" must be a boolean."))
            default:
                return .failure(CmsFunctionError("Input \"\(spec.name)\" must be a boolean."))
            }
        case "json":
            guard let encoded = try? JSONEncoder().encode(raw) else {
                return .failure(CmsFunctionError("Input \"\(spec.name)\" is not valid JSON data."))
            }
            if encoded.count > maxSourceBytes {
                return .failure(CmsFunctionError("Input \"\(spec.name)\" exceeds the maximum input size."))
            }
            return .success(raw)
        default:
            return .failure(CmsFunctionError("Unsupported input type \"\(spec.type)\"."))
        }
    }

    public static func bindPositionalInputs(_ fn: CmsFunctionDef, args: [CmsJSON]) -> Result<[String: CmsJSON], CmsFunctionError> {
        if args.count != fn.inputs.count {
            return .failure(CmsFunctionError("Function \"fn.\(fn.slug)\" expects \(fn.inputs.count) argument(s), got \(args.count)."))
        }
        var bound: [String: CmsJSON] = [:]
        for (idx, spec) in fn.inputs.enumerated() {
            switch coerceAndValidateInput(spec, raw: args[idx]) {
            case .success(let v): bound[spec.name] = v
            case .failure(let err): return .failure(err)
            }
        }
        return .success(bound)
    }

    public static func bindNamedInputs(_ fn: CmsFunctionDef, named: [String: CmsJSON]) -> Result<[String: CmsJSON], CmsFunctionError> {
        var bound: [String: CmsJSON] = [:]
        for spec in fn.inputs {
            switch coerceAndValidateInput(spec, raw: named[spec.name]) {
            case .success(let v): bound[spec.name] = v
            case .failure(let err): return .failure(err)
            }
        }
        return .success(bound)
    }

    public static func evaluateRawSync(_ fn: CmsFunctionDef, namedInputs: [String: CmsJSON]) -> Result<CmsJSON, CmsFunctionError> {
        if let defErr = validateDefinition(fn) {
            return .failure(CmsFunctionError(defErr))
        }
        let bound: [String: CmsJSON]
        switch bindNamedInputs(fn, named: namedInputs) {
        case .success(let b): bound = b
        case .failure(let err): return .failure(err)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let inputData = try? encoder.encode(CmsJSON.object(bound)),
              let inputJson = String(data: inputData, encoding: .utf8) else {
            return .failure(CmsFunctionError("Function \"\(fn.slug)\" inputs could not be encoded."))
        }
        if inputData.count > maxSourceBytes {
            return .failure(CmsFunctionError("Function \"\(fn.slug)\" inputs exceed the size limit."))
        }

        let filename = "\(fn.slug).js"
        let codeBytes = Array(fn.code.utf8)
        let inputBytes = Array(inputJson.utf8)

        var rawResult = CmsQjsEvalResult(status: 0, output_json: nil, error_message: nil)
        filename.withCString { filePtr in
            codeBytes.withUnsafeBufferPointer { codeBuf in
                inputBytes.withUnsafeBufferPointer { inputBuf in
                    let srcPtr = codeBuf.baseAddress.map { UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self) }
                    let inPtr = inputBuf.baseAddress.map { UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self) }
                    cms_qjs_eval(
                        filePtr,
                        srcPtr,
                        codeBuf.count,
                        inPtr,
                        inputBuf.count,
                        &rawResult
                    )
                }
            }
        }
        defer { cms_qjs_free_result(&rawResult) }

        if rawResult.status != Int32(CMS_QJS_OK.rawValue) {
            let msg = rawResult.error_message.map { String(cString: $0) } ?? "Function evaluation failed."
            return .failure(CmsFunctionError(msg))
        }

        guard let outPtr = rawResult.output_json else {
            return .success(.null)
        }
        let outJson = String(cString: outPtr)
        guard let outData = outJson.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(CmsJSON.self, from: outData) else {
            return .failure(CmsFunctionError("Function \"\(fn.slug)\" returned invalid JSON."))
        }
        if parsed == .null {
            return .success(.null)
        }
        switch fn.resultType {
        case "number":
            guard case .number(let n) = parsed, n.isFinite else {
                return .failure(CmsFunctionError("Function \"\(fn.slug)\" declared resultType \"number\" but returned a different type."))
            }
            return .success(.number(n))
        case "string":
            guard case .string(let s) = parsed else {
                return .failure(CmsFunctionError("Function \"\(fn.slug)\" declared resultType \"string\" but returned a different type."))
            }
            return .success(.string(s))
        case "boolean":
            guard case .bool(let b) = parsed else {
                return .failure(CmsFunctionError("Function \"\(fn.slug)\" declared resultType \"boolean\" but returned a different type."))
            }
            return .success(.bool(b))
        default:
            return .failure(CmsFunctionError("Unsupported resultType \"\(fn.resultType)\"."))
        }
    }

    public static func formState(from raw: Result<CmsJSON, CmsFunctionError>) -> CmsFormEvalState {
        switch raw {
        case .failure(let err):
            return .error(err.message)
        case .success(let json):
            switch json {
            case .null: return .value(.blank)
            case .number(let n): return .value(.number(n))
            case .string(let s): return .value(.text(s))
            case .bool(let b): return .value(.number(b ? 1 : 0))
            default: return .error("Function returned a non-scalar value.")
            }
        }
    }

    public static func evaluateSync(_ fn: CmsFunctionDef, namedInputs: [String: CmsJSON]) -> CmsFormEvalState {
        formState(from: evaluateRawSync(fn, namedInputs: namedInputs))
    }

    public static func evaluate(_ fn: CmsFunctionDef, namedInputs: [String: CmsJSON]) async -> CmsFormEvalState {
        let raw = await CmsFunctionWorkerActor.shared.run(fn, namedInputs: namedInputs)
        return formState(from: raw)
    }

    public static func runTests(_ fn: CmsFunctionDef) async -> CmsFunctionTestSuiteResult {
        if let defErr = validateDefinition(fn) {
            return CmsFunctionTestSuiteResult(
                passed: false,
                results: [CmsFunctionTestCaseResult(name: "definition", pass: false, expected: .null, actual: nil, error: defErr)]
            )
        }
        var results: [CmsFunctionTestCaseResult] = []
        for testCase in fn.tests ?? [] {
            let outcome = await CmsFunctionWorkerActor.shared.run(fn, namedInputs: testCase.input)
            switch outcome {
            case .failure(let err):
                results.append(CmsFunctionTestCaseResult(
                    name: testCase.name,
                    pass: false,
                    expected: testCase.expect,
                    actual: nil,
                    error: err.message
                ))
            case .success(let actual):
                let pass = actual == testCase.expect
                results.append(CmsFunctionTestCaseResult(
                    name: testCase.name,
                    pass: pass,
                    expected: testCase.expect,
                    actual: actual,
                    error: pass ? nil : "Expected \(testCase.expect), got \(actual)."
                ))
            }
        }
        return CmsFunctionTestSuiteResult(passed: results.allSatisfy(\.pass), results: results)
    }

    public static func cacheKey(siteRevision: String, fn: CmsFunctionDef, boundInput: [String: CmsJSON]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let inputJson = (try? encoder.encode(CmsJSON.object(boundInput))).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return "\(siteRevision)|\(fn.slug)|\(fn.resultType)|\(fn.code)|\(inputJson)"
    }
}
