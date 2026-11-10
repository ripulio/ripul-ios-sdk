import XCTest
@testable import RipulAgent

final class CmsFunctionRunnerTests: XCTestCase {
    private let calcPayFn = CmsFunctionDef(
        id: "fn_calc_pay",
        slug: "calc_pay",
        name: "Calculate pay",
        inputs: [
            CmsFunctionInputDef(name: "hours", type: "number"),
            CmsFunctionInputDef(name: "rate", type: "number"),
            CmsFunctionInputDef(name: "bonus", type: "number"),
        ],
        resultType: "number",
        code: """
        function compute(input) {
            if (input.hours === null || input.rate === null) return null;
            const bonus = input.bonus ?? 0;
            return Math.round((input.hours * input.rate + bonus) * 100) / 100;
        }
        """,
        tests: [
            CmsFunctionTestDef(
                name: "normal shift",
                input: ["hours": .number(8), "rate": .number(12.5), "bonus": .null],
                expect: .number(100)
            ),
            CmsFunctionTestDef(
                name: "with bonus",
                input: ["hours": .number(8), "rate": .number(12.5), "bonus": .number(15)],
                expect: .number(115)
            ),
            CmsFunctionTestDef(
                name: "blank hours returns null",
                input: ["hours": .null, "rate": .number(12.5), "bonus": .null],
                expect: .null
            ),
        ]
    )

    func testEvaluatesPureCalculationsAndRunsExampleTests() async {
        let state = await CmsFunctionRunner.evaluate(
            calcPayFn,
            namedInputs: ["hours": .number(7.5), "rate": .number(12), "bonus": .number(10)]
        )
        XCTAssertEqual(state, .value(.number(100)))

        let suite = await CmsFunctionRunner.runTests(calcPayFn)
        XCTAssertTrue(suite.passed)
        XCTAssertEqual(suite.results.count, 3)
        XCTAssertTrue(suite.results.allSatisfy(\.pass))
    }

    func testRejectsOutputTypeMismatchesAndFailedExampleAssertions() async {
        var wrongTypeFn = calcPayFn
        wrongTypeFn.code = "function compute() { return 'not a number'; }"
        let state = await CmsFunctionRunner.evaluate(
            wrongTypeFn,
            namedInputs: ["hours": .number(8), "rate": .number(10), "bonus": .number(0)]
        )
        if case .error(let msg) = state {
            XCTAssertTrue(msg.contains("resultType \"number\""), "unexpected message: \(msg)")
        } else {
            XCTFail("Expected error state, got \(state)")
        }

        var failingTestsFn = calcPayFn
        failingTestsFn.tests = [
            CmsFunctionTestDef(
                name: "wrong expectation",
                input: ["hours": .number(8), "rate": .number(10), "bonus": .number(0)],
                expect: .number(999)
            ),
        ]
        let suite = await CmsFunctionRunner.runTests(failingTestsFn)
        XCTAssertFalse(suite.passed)
        XCTAssertFalse(suite.results[0].pass)
    }

    func testEnforcesBusinessLogicBoundary() async {
        let forbidden: [(String, String)] = [
            ("eval", "function compute() { return eval('1 + 1'); }"),
            ("Function", "function compute() { return Function('return 1')(); }"),
            ("Math.random", "function compute() { return Math.random(); }"),
            ("Object.setPrototypeOf", "function compute() { const a = {}; Object.setPrototypeOf(a, {}); return 1; }"),
            ("Reflect.setPrototypeOf", "function compute() { const a = {}; Reflect.setPrototypeOf(a, {}); return 1; }"),
            ("__proto__", "function compute() { const a = {}; a.__proto__ = { x: 1 }; if (a.x === undefined) throw new Error('proto blocked'); return a.x; }"),
            ("Promise", "function compute() { return Promise.resolve(1); }"),
        ]

        for (label, code) in forbidden {
            let fn = CmsFunctionDef(
                id: "fn_boundary",
                slug: "check_boundary",
                name: label,
                inputs: [],
                resultType: "number",
                code: code
            )
            let state = await CmsFunctionRunner.evaluate(fn, namedInputs: [:])
            if case .error = state {
                // expected
            } else {
                XCTFail("\(label) should be rejected, got \(state)")
            }
        }
    }

    func testInterruptsInfiniteLoopWithinBudget() async {
        let fn = CmsFunctionDef(
            id: "fn_loop",
            slug: "infinite_loop",
            name: "Infinite loop",
            inputs: [],
            resultType: "number",
            code: "function compute() { while (true) {} }"
        )
        let state = await CmsFunctionRunner.evaluate(fn, namedInputs: [:])
        if case .error(let msg) = state {
            XCTAssertTrue(msg.contains("execution limit"), "unexpected message: \(msg)")
        } else {
            XCTFail("Expected timeout error, got \(state)")
        }
    }

    func testMultiHopFormExpressionsCoalesceTriStateAndSaveBlocking() async {
        let taxFn = CmsFunctionDef(
            id: "fn_calc_tax",
            slug: "calc_tax",
            name: "Calculate tax",
            inputs: [CmsFunctionInputDef(name: "gross", type: "number")],
            resultType: "number",
            code: "function compute(input) { return input.gross === null ? null : Math.round(input.gross * 20) / 100; }"
        )
        let inputs: [CmsActionInputDef] = {
            var hours = CmsActionInputDef(name: "hours", type: "float", required: true)
            var rate = CmsActionInputDef(name: "rate", type: "float", required: true)
            var net = CmsActionInputDef(name: "net", type: "float", required: false)
            net.fromComputed = "net"
            return [hours, rate, net]
        }()
        let computed = [
            CmsComputedDef(name: "gross", expr: "hours * rate", format: nil),
            CmsComputedDef(name: "tax", expr: "coalesce(fn.calc_tax(gross), 0)", format: nil),
            CmsComputedDef(name: "net", expr: "gross - tax", format: nil),
        ]
        let cache = CmsFunctionResultCache()
        let formValues = CmsFormValues(
            inputs: inputs,
            computed: computed,
            draft: ["hours": .text("8"), "rate": .text("12.5")],
            functions: ["calc_tax": taxFn],
            siteRevision: "site_1",
            functionCache: cache
        )

        // Before off-main resolution, tax and net are .pending (coalesce does NOT swallow .pending!)
        let initialStates = formValues.computedStates
        XCTAssertEqual(initialStates["gross"], .value(.number(100)))
        XCTAssertEqual(initialStates["tax"], .pending)
        XCTAssertEqual(initialStates["net"], .pending)

        // Validation while pending blocks Save and does NOT send null for optional `net`
        let pendingCheck = CmsActionForm.validate(
            inputs,
            draft: ["hours": .text("8"), "rate": .text("12.5")],
            computedStates: initialStates
        )
        XCTAssertFalse(pendingCheck.ready)
        XCTAssertNil(pendingCheck.values["net"])
        XCTAssertEqual(pendingCheck.errors.first?.field, "net")

        // Resolve off-main and verify final values and validation
        let resolvedStates = await formValues.resolveAllFunctions()
        XCTAssertEqual(resolvedStates["gross"], .value(.number(100)))
        XCTAssertEqual(resolvedStates["tax"], .value(.number(20)))
        XCTAssertEqual(resolvedStates["net"], .value(.number(80)))

        let readyCheck = CmsActionForm.validate(
            inputs,
            draft: ["hours": .text("8"), "rate": .text("12.5")],
            computedStates: resolvedStates
        )
        XCTAssertTrue(readyCheck.ready)
        XCTAssertEqual(readyCheck.values["net"], .number(80))

        // Error on a fromComputed input blocks Save and does NOT send null
        let errorCheck = CmsActionForm.validate(
            inputs,
            draft: ["hours": .text("8"), "rate": .text("12.5")],
            computedStates: [
                "gross": .value(.number(100)),
                "tax": .error("Tax rate missing"),
                "net": .error("Tax rate missing"),
            ]
        )
        XCTAssertFalse(errorCheck.ready)
        XCTAssertNil(errorCheck.values["net"])
        XCTAssertEqual(errorCheck.errors.first?.field, "net")
        XCTAssertTrue(errorCheck.errors.first?.message.contains("Tax rate missing") == true)
    }
}
