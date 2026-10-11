import Foundation

/// Features that ship switched off and are turned on by hand, from
/// Settings → Experimental Features.
///
/// The key lives in the SDK because both sides read it: the host app hides its
/// own routes to the feature, and the SDK hides the ones it draws itself (the
/// Plan review row in the quick commands sheet). Absent means off, so a host
/// that never offers the switch never shows the feature.
public enum RipulExperimentalFeatures {
    /// Plans: the Plans screen, the Agents|Plans switch and Plan review.
    public static let plansKey = "experimentalPlans"
}
