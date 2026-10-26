import SwiftUI

public struct ClaudeAccountsSettingsScreen: View {
    let bridge: AgentBridge

    public init(bridge: AgentBridge) { self.bridge = bridge }

    public var body: some View {
        CodingAccountsSettingsList(provider: .claude, bridge: bridge)
    }
}
