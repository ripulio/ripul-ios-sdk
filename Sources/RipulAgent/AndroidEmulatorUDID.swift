import Foundation

/// Android emulators travel the iOS simulators' path under a UDID the Mac
/// makes from each AVD's name: a UUID of version 8, where an iOS simulator's
/// is version 4. So the version digit alone says which platform a UDID names,
/// for a label or a set of buttons, with nothing to look up.
/// See chrome-extension/docs/architecture/androidEmulators.md.
public enum AndroidEmulatorUDID {
    public static func isAndroid(_ udid: String) -> Bool {
        guard UUID(uuidString: udid) != nil else { return false }
        let characters = Array(udid)
        return characters.count == 36 && characters[14] == "8"
    }
}
