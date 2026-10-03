#if canImport(UIKit)
import SwiftUI
import UIKit

// MARK: - The support session's screen

/// The customer's side of a support session, from asking for help to the
/// moment the supporter can see the app: the code to read out, who is asking
/// to look, and the customer's answer. Put it in a sheet (`ripulSupportSheet`)
/// or present it from UIKit (`RipulSupport.present(from:configuration:)`).
///
/// Once sharing starts the sheet closes itself, so the customer can show what
/// they need help with; from then on the pill at the top of the screen says
/// who is watching and has Stop. Closing the sheet before that cancels the
/// request.
public struct RipulSupportView: View {
    private let configuration: RipulSupportConfiguration
    private let support = RipulSupport.shared
    @Environment(\.dismiss) private var dismiss

    public init(configuration: RipulSupportConfiguration) {
        self.configuration = configuration
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Its own title and way out, not a navigation bar's: a host app may hide every
            // navigation bar, and a sheet that can't be swiped away must still have Cancel.
            ZStack {
                Text("Get Help")
                    .font(.headline)
                HStack {
                    Button(closeTitle) { close() }
                        .uiKitIdentifier("RipulSupportView.close")
                    Spacer()
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 8)
            // The words scroll if the sheet is short; the answer is always in reach under them.
            ScrollView {
                VStack(spacing: 16) {
                    content
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .frame(maxWidth: 480)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .safeAreaInset(edge: .bottom) {
                actions
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .frame(maxWidth: 480)
                    .frame(maxWidth: .infinity)
            }
        }
        .interactiveDismissDisabled(isBusy)
        .onAppear {
            // A session that ended while the sheet was closed is not the news on opening it again.
            support.reset()
            if !support.isActive { support.start(configuration) }
        }
        .onChange(of: support.phase) { _, phase in
            // The supporter can see the app now: get out of its way.
            if case .sharing = phase { dismiss() }
        }
        .uiKitIdentifier("RipulSupportView")
    }

    /// Before sharing starts the sheet is the session: it closes with Cancel, not a stray swipe.
    private var isBusy: Bool {
        switch support.phase {
        case .starting, .waiting, .asking: true
        default: false
        }
    }

    private var closeTitle: String {
        switch support.phase {
        case .starting, .waiting, .asking: "Cancel"
        default: "Close"
        }
    }

    private func close() {
        switch support.phase {
        case .starting, .waiting, .asking: support.stop()
        default: break
        }
        dismiss()
    }

    @ViewBuilder
    private var content: some View {
        switch support.phase {
        case .idle, .starting:
            ProgressView()
                .controlSize(.large)
            Text("Getting a code…")
                .font(.headline)
        case .waiting(let code):
            Text("Read this code to the person helping you")
                .font(.headline)
                .multilineTextAlignment(.center)
            RipulSupportCode(code: code)
            Text("They will ask to see \(RipulLiveViewIdentity.appName). Nothing is shared until you agree.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 8) {
                ProgressView()
                Text("Waiting for them to enter it…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        case .asking(_, let supporter):
            Text("\(supporter) would like to see \(RipulLiveViewIdentity.appName)")
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
                .uiKitIdentifier("RipulSupportView.asking")
            VStack(alignment: .leading, spacing: 10) {
                RipulSupportPoint(symbol: "app.badge.checkmark",
                                  text: "They see this app only, not the rest of your \(deviceWord).")
                RipulSupportPoint(symbol: "hand.point.up.left",
                                  text: "They can point at things. They can't tap, type or change anything.")
                RipulSupportPoint(symbol: "stop.circle",
                                  text: "You can stop at any time, at the top of the screen.")
            }
        case .sharing(let supporter):
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 52))
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            Text(support.isPaused ? "Waiting for \(supporter) to reconnect…" : "\(supporter) can see \(RipulLiveViewIdentity.appName)")
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
        case .ended(let reason):
            Image(systemName: "checkmark.circle")
                .font(.system(size: 52))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(reason)
                .font(.headline)
                .multilineTextAlignment(.center)
            Text("Nothing is being shared.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        case .failed(let reason):
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 52))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(reason)
                .font(.headline)
                .multilineTextAlignment(.center)
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch support.phase {
        case .asking:
            VStack(spacing: 10) {
                Button {
                    support.allow()
                } label: {
                    Text("Allow").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .uiKitIdentifier("RipulSupportView.allow")
                Button {
                    support.stop()
                } label: {
                    Text("Don't Allow").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .uiKitIdentifier("RipulSupportView.decline")
            }
        case .sharing:
            Button(role: .destructive) {
                support.stop()
            } label: {
                Text("Stop Sharing").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .uiKitIdentifier("RipulSupportView.stop")
        case .ended, .failed:
            Button {
                support.reset()
                support.start(configuration)
            } label: {
                Text("Get a New Code").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .uiKitIdentifier("RipulSupportView.again")
        default:
            EmptyView()
        }
    }

    private var deviceWord: String {
        UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
    }
}

/// The code, big enough to read out: "482 913".
private struct RipulSupportCode: View {
    let code: String

    private var spaced: String {
        code.count == 6 ? "\(code.prefix(3)) \(code.suffix(3))" : code
    }

    var body: some View {
        Text(spaced)
            .font(.system(size: 52, weight: .bold, design: .rounded))
            .monospacedDigit()
            .minimumScaleFactor(0.5)
            .lineLimit(1)
            .textSelection(.enabled)
            .padding(.vertical, 6)
            .accessibilityLabel(code.map(String.init).joined(separator: " "))
            .uiKitIdentifier("RipulSupportView.code")
    }
}

private struct RipulSupportPoint: View {
    let symbol: String
    let text: String

    var body: some View {
        Label {
            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(.tint)
        }
    }
}

public extension View {
    /// Presents the support session's screen: ask for a code, wait for the
    /// supporter, agree. Bind it to whatever the app's "Get help" button sets.
    func ripulSupportSheet(isPresented: Binding<Bool>, configuration: RipulSupportConfiguration) -> some View {
        sheet(isPresented: isPresented) {
            RipulSupportView(configuration: configuration)
                .presentationDetents([.medium, .large])
        }
    }
}

public extension RipulSupport {
    /// Presents the support session's screen from a UIKit app.
    func present(from presenter: UIViewController, configuration: RipulSupportConfiguration) {
        let host = UIHostingController(rootView: RipulSupportView(configuration: configuration))
        if let sheet = host.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        presenter.present(host, animated: true)
    }
}
#endif
