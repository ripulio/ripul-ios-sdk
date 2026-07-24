import SwiftUI

/// Grid of SF Symbols for assigning an icon to a remote machine.
struct MachineIconPicker: View {
    let machineName: String
    let currentIcon: String?
    let onSelect: (String?) -> Void

    @Environment(\.dismiss) private var dismiss

    /// Curated SF Symbols that make sense as machine identifiers.
    private static let availableIcons: [(section: String, icons: [String])] = [
        ("Computers", [
            "desktopcomputer", "laptopcomputer", "macbook",
            "display", "server.rack", "pc",
        ]),
        ("Devices", [
            "cpu", "memorychip", "externaldrive.fill",
            "hifispeaker.fill", "tv", "gamecontroller.fill",
        ]),
        ("Network", [
            "network", "globe", "cloud.fill",
            "antenna.radiowaves.left.and.right", "wifi",
            "link",
        ]),
        ("Places", [
            "house.fill", "building.2.fill", "briefcase.fill",
            "wrench.and.screwdriver.fill", "hammer.fill",
            "flask.fill",
        ]),
        ("Symbols", [
            "star.fill", "heart.fill", "bolt.fill",
            "flame.fill", "leaf.fill", "moon.fill",
            "sun.max.fill", "snowflake", "drop.fill",
            "diamond.fill", "shield.fill", "flag.fill",
        ]),
    ]

    private let columns = [
        GridItem(.adaptive(minimum: 52, maximum: 64), spacing: 12),
    ]

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(Self.availableIcons, id: \.section) { group in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(group.section)
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                                .padding(.horizontal, 4)

                            LazyVGrid(columns: columns, spacing: 12) {
                                ForEach(group.icons, id: \.self) { icon in
                                    iconButton(icon)
                                }
                            }
                        }
                    }
                }
                .padding(20)
            }
            .navigationTitle("Icon for \(machineName)")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .uiKitIdentifier("MachineIconPicker.cancelButton")
                }
                ToolbarItem(placement: .primaryAction) {
                    if currentIcon != nil {
                        Button("Remove") {
                            onSelect(nil)
                            dismiss()
                        }
                        .uiKitIdentifier("MachineIconPicker.removeButton")
                    }
                }
            }
            #else
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .uiKitIdentifier("MachineIconPicker.cancelButton")
                }
            }
            #endif
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #endif
    }

    private func iconButton(_ icon: String) -> some View {
        let isSelected = currentIcon == icon
        return Button {
            onSelect(icon)
            dismiss()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundStyle(isSelected ? .white : .primary)
                .frame(width: 48, height: 48)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(isSelected ? Color.accentColor : Color.primary.opacity(0.08))
                )
        }
        .buttonStyle(.plain)
    }
}
