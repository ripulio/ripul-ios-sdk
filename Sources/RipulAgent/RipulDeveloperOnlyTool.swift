import Foundation

/// Marker for native tools that must never reach an `.endUser` `AgentBridge`
/// channel. SDK-internal on purpose: only the SDK's own dev tools may conform,
/// so a host cannot mark its own tool "developer-only" (or strip the marker
/// from one of these) and change what the gate does.
///
/// `AgentBridge` enforces this at the single point every tool list is read
/// from (`allTools`), which is what both the `mcp:tools` broadcast and
/// `handleMCPInvoke`'s lookup derive from — so the hard gate holds regardless
/// of whether a tool was registered via `register`, `registerBuiltInTools`,
/// or `setTools`, and regardless of which of those a future call site uses.
///
/// See docs/plans/native-tool-registry/phase-0-hard-gate-and-decision-record.md.
protocol RipulDeveloperOnlyTool: NativeTool {}

// MARK: - Diagnostics

extension ConsoleLogsTool: RipulDeveloperOnlyTool {}
extension NetworkLogsTool: RipulDeveloperOnlyTool {}
extension InspectScreenTool: RipulDeveloperOnlyTool {}

// MARK: - Screen actuation (ScreenActuationTools.swift is #if canImport(UIKit) — mirror that here)

#if canImport(UIKit)
extension TapElementTool: RipulDeveloperOnlyTool {}
extension TypeTextTool: RipulDeveloperOnlyTool {}
extension ScrollElementTool: RipulDeveloperOnlyTool {}
extension WaitForElementTool: RipulDeveloperOnlyTool {}
extension ExplorerProbeTool: RipulDeveloperOnlyTool {}
extension ExplorerConformanceTool: RipulDeveloperOnlyTool {}
extension SetValueTool: RipulDeveloperOnlyTool {}
#endif

// MARK: - Theme control (ThemeControlTools.swift is #if os(iOS) — mirror that here)

#if os(iOS)
extension RipulListThemeScopesTool: RipulDeveloperOnlyTool {}
extension RipulGetThemeStyleTool: RipulDeveloperOnlyTool {}
extension RipulSetThemeKnobTool: RipulDeveloperOnlyTool {}
extension RipulResetThemeScopeTool: RipulDeveloperOnlyTool {}
extension RipulGetAppDiagnosticsTool: RipulDeveloperOnlyTool {}
#endif

// MARK: - Tool collections

extension RipulListToolCollectionsTool: RipulDeveloperOnlyTool {}
extension RipulCreateToolCollectionTool: RipulDeveloperOnlyTool {}
extension RipulUpdateToolCollectionTool: RipulDeveloperOnlyTool {}
extension RipulDeleteToolCollectionTool: RipulDeveloperOnlyTool {}
