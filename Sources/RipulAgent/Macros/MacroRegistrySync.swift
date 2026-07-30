import Foundation

#if canImport(UIKit)
/// The one place "fetch macros → wrap each in a MacroTool → register by
/// audience" happens — shared by `RipulAgentConsole`'s boot-time refresh and
/// `SolutionManagementSection`'s Macros row (docs/plans/automation-macros/
/// phase-4-…), so the two call sites can't drift apart. `MacroTool` needs
/// UIKit (it replays through `LiveScreenResolver`), which is why this lives
/// here rather than alongside the UIKit-independent `MacroRegistrationPlanner`.
@MainActor
enum MacroRegistrySync {
    static func refresh(client: RipulMacroClient, registry: RipulToolRegistry) async {
        guard let macros = try? await client.list() else { return }
        let plan = MacroRegistrationPlanner.plan(macros)
        registry.setTools(plan.developer.map { MacroTool(macro: $0) }, audience: .developer)
        registry.setTools(plan.endUser.map { MacroTool(macro: $0) }, audience: .endUser)
    }
}
#endif
