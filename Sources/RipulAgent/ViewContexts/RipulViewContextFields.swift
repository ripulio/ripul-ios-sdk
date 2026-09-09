#if os(iOS)
import Foundation

/// Matches ViewContextFeatures in config/interfaces.ts. Missing values remain
/// missing so the consuming surface retains its own defaults.
struct RipulViewContextField: Identifiable {
    enum Kind { case boolean, number, text, allowlist, choice([String]) }
    let key: String
    let title: String
    let group: String
    let kind: Kind
    var id: String { key }
    static let groups = ["Chat features", "Appearance", "Agent identity", "Thinking", "Tool calls", "Welcome screen", "Masthead"]
    static let all: [Self] = [
        .init(key: "modelSelection", title: "Model selection", group: "Chat features", kind: .boolean),
        .init(key: "imageAttachments", title: "Image attachments", group: "Chat features", kind: .boolean),
        .init(key: "exportChat", title: "Export chat", group: "Chat features", kind: .boolean),
        .init(key: "webTools", title: "Web tools", group: "Chat features", kind: .boolean),
        .init(key: "workflowView", title: "Workflow view", group: "Chat features", kind: .boolean),
        .init(key: "workflowEdit", title: "Workflow edit", group: "Chat features", kind: .boolean),
        .init(key: "showUsage", title: "Show usage", group: "Chat features", kind: .boolean),
        .init(key: "multiTabChat", title: "Multi tab chat", group: "Chat features", kind: .boolean),
        .init(key: "autocomplete", title: "Autocomplete", group: "Chat features", kind: .boolean),
        .init(key: "timelineMode", title: "Timeline mode", group: "Chat features", kind: .choice(["user", "solution-builder", "developer", "admin"])),
        .init(key: "showSidebarNav", title: "Show sidebar nav", group: "Chat features", kind: .boolean),
        .init(key: "slashCommands", title: "Slash commands", group: "Chat features", kind: .allowlist),
        .init(key: "atCommands", title: "At commands", group: "Chat features", kind: .allowlist),
        .init(key: "bubbleActions", title: "Bubble actions", group: "Chat features", kind: .allowlist),
        .init(key: "hideWelcomeScreen", title: "Hide welcome screen", group: "Welcome screen", kind: .boolean),
        .init(key: "userMessageNavigation", title: "User message navigation", group: "Chat features", kind: .boolean),
        .init(key: "showThinkingPanels", title: "Show thinking panels", group: "Thinking", kind: .boolean),
        .init(key: "promptCollectionId", title: "Prompt collection id", group: "Welcome screen", kind: .text),
        .init(key: "inlineThinkingFontSize", title: "Inline thinking font size", group: "Thinking", kind: .number),
        .init(key: "inlineThinkingMaxHeight", title: "Inline thinking max height", group: "Thinking", kind: .number),
        .init(key: "chatBottomBuffer", title: "Chat bottom buffer", group: "Appearance", kind: .number),
        .init(key: "uiScale", title: "Ui scale", group: "Appearance", kind: .number),
        .init(key: "hideSendButton", title: "Hide send button", group: "Chat features", kind: .boolean),
        .init(key: "showAgentAvatar", title: "Show agent avatar", group: "Agent identity", kind: .boolean),
        .init(key: "agentAvatarIcon", title: "Agent avatar icon", group: "Agent identity", kind: .text),
        .init(key: "welcomeLogoUrl", title: "Welcome logo url", group: "Welcome screen", kind: .text),
        .init(key: "welcomeLogoWidth", title: "Welcome logo width", group: "Welcome screen", kind: .text),
        .init(key: "welcomeTitle", title: "Welcome title", group: "Welcome screen", kind: .text),
        .init(key: "welcomeDescription", title: "Welcome description", group: "Welcome screen", kind: .text),
        .init(key: "chatInputBorderColor", title: "Chat input border color", group: "Appearance", kind: .text),
        .init(key: "chatInputBackgroundColor", title: "Chat input background color", group: "Appearance", kind: .text),
        .init(key: "chatWindowBackgroundColor", title: "Chat window background color", group: "Appearance", kind: .text),
        .init(key: "chatAreaBackgroundColor", title: "Chat area background color", group: "Appearance", kind: .text),
        .init(key: "welcomeTextColor", title: "Welcome text color", group: "Welcome screen", kind: .text),
        .init(key: "welcomeBackgroundColor", title: "Welcome background color", group: "Welcome screen", kind: .text),
        .init(key: "panelBackgroundColor", title: "Panel background color", group: "Appearance", kind: .text),
        .init(key: "userMessageBackgroundColor", title: "User message background color", group: "Appearance", kind: .text),
        .init(key: "toolCallSummaryMode", title: "Tool call summary mode", group: "Tool calls", kind: .choice(["list", "latest"])),
        .init(key: "toolCallExpandable", title: "Tool call expandable", group: "Tool calls", kind: .boolean),
        .init(key: "toolCallDefaultExpanded", title: "Tool call default expanded", group: "Tool calls", kind: .boolean),
        .init(key: "chatBorderRadius", title: "Chat border radius", group: "Appearance", kind: .text),
        .init(key: "toolCallSummaryLabel", title: "Tool call summary label", group: "Tool calls", kind: .text),
        .init(key: "toolCallSummaryPendingLabel", title: "Tool call summary pending label", group: "Tool calls", kind: .text),
        .init(key: "toolCallFontFamily", title: "Tool call font family", group: "Tool calls", kind: .text),
        .init(key: "toolCallFontSize", title: "Tool call font size", group: "Tool calls", kind: .text),
        .init(key: "toolCallIcon", title: "Tool call icon", group: "Tool calls", kind: .text),
        .init(key: "toolCallSummaryLayout", title: "Tool call summary layout", group: "Tool calls", kind: .choice(["list", "chips"])),
        .init(key: "mastheadText", title: "Masthead text", group: "Masthead", kind: .text),
        .init(key: "mastheadImageUrl", title: "Masthead image url", group: "Masthead", kind: .text),
        .init(key: "mastheadBackgroundColor", title: "Masthead background color", group: "Masthead", kind: .text),
        .init(key: "mastheadTextColor", title: "Masthead text color", group: "Masthead", kind: .text),
        .init(key: "mastheadHeight", title: "Masthead height", group: "Masthead", kind: .number),
        .init(key: "mastheadImageWidth", title: "Masthead image width", group: "Masthead", kind: .text),
        .init(key: "mastheadFontSize", title: "Masthead font size", group: "Masthead", kind: .number),
        .init(key: "mastheadSticky", title: "Masthead sticky", group: "Masthead", kind: .boolean),
        .init(key: "mastheadTopOffset", title: "Masthead top offset", group: "Masthead", kind: .number),
        .init(key: "mastheadGlassStyle", title: "Masthead glass style", group: "Masthead", kind: .choice(["regular", "clear", "identity"])),
        .init(key: "chatInputGlassStyle", title: "Chat input glass style", group: "Appearance", kind: .choice(["regular", "clear", "identity"])),
        .init(key: "chatInputLayout", title: "Chat input layout", group: "Appearance", kind: .choice(["single", "twoRow"])),
        .init(key: "hideGutterOnMobile", title: "Hide gutter on mobile", group: "Appearance", kind: .boolean),
        .init(key: "respondentLabelMode", title: "Respondent label mode", group: "Agent identity", kind: .choice(["model", "custom", "hidden"])),
        .init(key: "respondentLabelText", title: "Respondent label text", group: "Agent identity", kind: .text),
        .init(key: "respondentLabelIcon", title: "Respondent label icon", group: "Agent identity", kind: .text),
        .init(key: "respondentLabelColor", title: "Respondent label color", group: "Agent identity", kind: .text),
    ]
}
#endif
