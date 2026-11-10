import SwiftUI
import WidgetKit
import RipulLiveActivity

/// The running shift on the Lock Screen and in the Dynamic Island. The SDK's
/// runtime starts, updates and ends it from the site's `action.after.activity`.
@main
struct WACNextWidgets: WidgetBundle {
    var body: some Widget {
        CmsRunningActivityWidget()
    }
}
