import SwiftUI

struct ContentView: View {
    @StateObject private var calendarService = CalendarService.shared
    @StateObject private var bridge = AgentBridge()
    @State private var showAgent = false
    @State private var selectedTab = 0
    @State private var agentReady = false
    @State private var permissionDenied = false
    @AppStorage("agentBaseURL") private var baseURLString = AgentConfiguration.defaultBaseURL.absoluteString
    @AppStorage("agentSiteKey") private var siteKey = "pk_live_2pakky4z3s9674wu9zvvgzze"

    private var agentConfiguration: AgentConfiguration {
        AgentConfiguration(
            baseURL: URL(string: baseURLString) ?? AgentConfiguration.defaultBaseURL,
            siteKey: siteKey.isEmpty ? nil : siteKey
        )
    }

    var body: some View {
        ZStack {
            TabView(selection: $selectedTab) {
                // Calendar tab
                NavigationStack {
                    Group {
                        if calendarService.hasAccess {
                            WeekCalendarView(calendarService: calendarService)
                        } else {
                            permissionView
                        }
                    }
                    .navigationTitle("Calendar")
                }
                .tag(0)
                .tabItem { Label("Calendar", systemImage: "calendar") }

                // Agent tab (intercepted — opens overlay instead)
                Color.clear
                    .tag(1)
                    .tabItem { Label("Agent", systemImage: "sparkles") }

                // Guide tab
                NavigationStack {
                    GuideView()
                        .navigationTitle("Guide")
                }
                .tag(2)
                .tabItem { Label("Guide", systemImage: "book") }

                // Settings tab
                NavigationStack {
                    SettingsView()
                        .navigationTitle("Settings")
                }
                .tag(3)
                .tabItem { Label("Settings", systemImage: "gear") }
            }
            .onChange(of: selectedTab) { _, newTab in
                if newTab == 1 {
                    // Intercept the Agent tab — open the overlay instead
                    selectedTab = 0
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
                        showAgent = true
                    }
                }
            }

            // Agent layer — always in hierarchy, preloaded, slides up from bottom
            agentPanel
                .offset(y: showAgent ? 0 : UIScreen.main.bounds.height + 100)
                .animation(.spring(response: 0.35, dampingFraction: 0.86), value: showAgent)
        }
        .task {
            bridge.register(ExampleTools.all)
            let granted = await calendarService.requestAccess()
            if !granted { permissionDenied = true }
        }
        .onChange(of: bridge.isThemeReady) { _, ready in
            if ready { agentReady = true }
        }
        .onChange(of: bridge.wantsMinimize) { _, minimize in
            if minimize {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
                    showAgent = false
                }
            }
        }
    }

    // MARK: - Agent Panel

    private var agentPanel: some View {
        VStack(spacing: 0) {
            // Drag handle + close button
            HStack {
                Spacer()
                RoundedRectangle(cornerRadius: 2.5)
                    .fill(Color(.systemGray4))
                    .frame(width: 36, height: 5)
                Spacer()
            }
            .overlay(alignment: .trailing) {
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
                        showAgent = false
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .padding(.trailing, 16)
            }
            .padding(.top, 10)
            .padding(.bottom, 6)

            // Agent WebView — always loaded
            AgentWebView(configuration: agentConfiguration, bridge: bridge)
        }
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .shadow(color: .black.opacity(0.15), radius: 20, y: -5)
        .padding(.top, 50) // Leave room at top so calendar peeks through
        .ignoresSafeArea(.container, edges: .bottom)
    }

    // MARK: - Permission View

    private var permissionView: some View {
        VStack(spacing: 16) {
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)

            Text("Calendar Access Required")
                .font(.title3.weight(.semibold))

            Text("This app needs access to your calendar so the AI agent can view and create events.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            if permissionDenied {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    ContentView()
}
