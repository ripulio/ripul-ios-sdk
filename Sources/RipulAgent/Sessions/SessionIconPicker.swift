import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Grid of SF Symbols for assigning a user-chosen icon to a chat session,
/// standing in for the model/provider icon in `UnifiedSessionRow`.
public struct SessionIconPicker: View {
    public let sessionTitle: String
    public let currentIcon: String?
    public let onSelect: (String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var selectedSection: String?

    /// Curated SF Symbols suitable for chat sessions.
    public static let availableIcons: [(section: String, icons: [String])] = [
        ("Coding & Tools", [
            "terminal.fill", "chevron.left.forwardslash.chevron.right", "curlybraces",
            "curlybraces.square.fill", "applescript.fill", "function",
            "fx", "number.square.fill", "command",
            "option", "keyboard.fill", "hammer.fill",
            "wrench.and.screwdriver.fill", "screwdriver.fill", "gearshape.fill",
            "gearshape.2.fill", "slider.horizontal.3", "cpu",
            "memorychip", "cable.connector", "powerplug.fill",
            "puzzlepiece.extension.fill", "puzzlepiece.fill", "cube.fill",
            "shippingbox.fill", "cylinder.split.1x2.fill", "tray.2.fill",
        ]),
        ("Git & Workflows", [
            "arrow.triangle.branch", "arrow.triangle.pull", "arrow.triangle.merge",
            "arrow.triangle.swap", "arrow.triangle.2.circlepath", "point.3.connected.trianglepath.dotted",
            "timeline.selection", "tag.fill", "checkmark.circle.fill",
            "xmark.octagon.fill", "exclamationmark.triangle.fill", "clock.arrow.circlepath",
            "play.fill", "bolt.horizontal.fill", "flag.checkered",
            "paperplane.fill", "tray.full.fill", "archivebox.fill",
        ]),
        ("AI & Agents", [
            "sparkles", "wand.and.stars", "brain.head.profile",
            "brain", "atom", "waveform",
            "waveform.path.ecg", "bubble.left.and.bubble.right.fill", "text.bubble.fill",
            "quote.bubble.fill", "questionmark.bubble.fill", "person.wave.2.fill",
            "sparkle.magnifyingglass", "eye.fill", "rays",
            "infinity", "gyroscope", "hurricane",
        ]),
        ("Bugs & Testing", [
            "ladybug.fill", "ant.fill", "stethoscope",
            "cross.case.fill", "bandage.fill", "pills.fill",
            "syringe.fill", "heart.text.square.fill", "checkmark.seal.fill",
            "checkmark.shield.fill", "bolt.shield.fill", "shield.lefthalf.filled",
            "flame.fill", "fire.extinguisher.fill", "magnifyingglass",
            "scope", "target", "gauge.with.dots.needle.67percent",
            "speedometer", "stopwatch.fill", "timer",
        ]),
        ("Design & Media", [
            "paintbrush.fill", "paintbrush.pointed.fill", "swatchpalette.fill",
            "paintpalette.fill", "eyedropper.halffull", "pencil.and.ruler.fill",
            "ruler.fill", "crop", "scribble.variable",
            "wand.and.rays", "photo.fill", "photo.on.rectangle.angled",
            "camera.fill", "video.fill", "film.fill",
            "play.rectangle.fill", "music.note", "headphones",
            "mic.fill", "speaker.wave.3.fill", "theatermasks.fill",
            "guitars.fill", "gamecontroller.fill", "dice.fill",
        ]),
        ("Devices & Hardware", [
            "iphone", "ipad", "macbook",
            "desktopcomputer", "macwindow", "macpro.gen3.fill",
            "macmini.fill", "display", "display.2",
            "applewatch", "visionpro", "airpodspro",
            "homepod.fill", "appletv.fill", "tv.fill",
            "printer.fill", "scanner.fill", "sensor.fill",
        ]),
        ("Systems & Web", [
            "server.rack", "externaldrive.fill", "internaldrive.fill",
            "opticaldisc.fill", "cloud.fill", "icloud.fill",
            "cloud.bolt.fill", "network", "globe",
            "globe.americas.fill", "globe.europe.africa.fill", "globe.asia.australia.fill",
            "safari.fill", "wifi", "antenna.radiowaves.left.and.right",
            "dot.radiowaves.left.and.right", "link", "personalhotspot",
        ]),
        ("Security & Keys", [
            "lock.shield.fill", "lock.fill", "lock.open.fill",
            "key.fill", "key.horizontal.fill", "touchid",
            "faceid", "opticid", "person.badge.key.fill",
            "person.badge.shield.checkmark.fill", "hand.raised.fill", "eye.slash.fill",
            "checkerboard.shield", "seal.fill", "signature",
        ]),
        ("Docs & Planning", [
            "doc.text.fill", "doc.richtext.fill", "doc.plaintext.fill",
            "doc.append.fill", "doc.on.doc.fill", "folder.fill",
            "folder.badge.gearshape", "book.fill", "books.vertical.fill",
            "text.book.closed.fill", "newspaper.fill", "magazine.fill",
            "note.text", "pencil.line", "highlighter",
            "paperclip", "bookmark.fill", "graduationcap.fill",
            "list.bullet.clipboard.fill", "checklist", "checklist.checked",
            "tablecells.fill", "rectangle.grid.2x2.fill", "square.stack.3d.up.fill",
            "calendar", "calendar.badge.clock", "clock.fill",
            "hourglass", "alarm.fill", "lightbulb.fill",
        ]),
        ("Charts & Commerce", [
            "chart.bar.fill", "chart.line.uptrend.xyaxis", "chart.pie.fill",
            "chart.xyaxis.line", "chart.bar.doc.horizontal.fill", "percent",
            "creditcard.fill", "banknote.fill", "dollarsign.circle.fill",
            "sterlingsign.circle.fill", "eurosign.circle.fill", "bitcoinsign.circle.fill",
            "cart.fill", "bag.fill", "basket.fill",
            "gift.fill", "ticket.fill", "receipt.fill",
            "scalemass.fill", "building.columns.fill", "storefront.fill",
        ]),
        ("People & Places", [
            "person.fill", "person.2.fill", "person.3.fill",
            "person.crop.circle.fill", "person.2.wave.2.fill", "figure.walk",
            "figure.run", "figure.wave", "hand.thumbsup.fill",
            "hand.wave.fill", "hands.clap.fill", "megaphone.fill",
            "envelope.fill", "phone.fill", "building.2.fill",
            "house.fill", "briefcase.fill", "tent.fill",
        ]),
        ("Maps, Science & Travel", [
            "map.fill", "mappin.and.ellipse", "location.fill",
            "location.north.line.fill", "compass.drawing", "signpost.right.fill",
            "binoculars.fill", "flask.fill", "testtube.2",
            "airplane", "car.fill", "bus.fill",
            "tram.fill", "bicycle", "ferry.fill",
            "sailboat.fill", "fuelpump.fill", "globe.desk.fill",
        ]),
        ("Nature & Food", [
            "sun.max.fill", "moon.fill", "moon.stars.fill",
            "cloud.sun.fill", "cloud.rain.fill", "snowflake",
            "wind", "tornado", "bolt.fill",
            "drop.fill", "leaf.fill", "tree.fill",
            "camera.macro", "mountain.2.fill", "water.waves",
            "pawprint.fill", "hare.fill", "tortoise.fill",
            "bird.fill", "fish.fill", "cup.and.saucer.fill",
            "mug.fill", "fork.knife", "carrot.fill",
            "birthday.cake.fill", "wineglass.fill", "takeoutbag.and.cup.and.straw.fill",
        ]),
        ("Symbols & Awards", [
            "star.fill", "heart.fill", "diamond.fill",
            "crown.fill", "trophy.fill", "medal.fill",
            "rosette", "flag.fill", "flag.2.crossed.fill",
            "bell.fill", "bell.badge.fill", "flashlight.on.fill",
            "umbrella.fill", "pin.fill", "scissors",
            "lifepreserver.fill", "balloon.2.fill", "party.popper.fill",
            "fireworks", "shield.checkered", "key.radiowaves.forward.fill",
        ]),
    ]

    /// Section-level search keywords so queries like "code", "git", "ai", "bug",
    /// "db", "auth", "money", "coffee", or "central command" find matching icons.
    private static let sectionKeywords: [String: String] = [
        "Coding & Tools": "code coding dev developer cli shell bash terminal build compile script tool plugin package database db sql",
        "Git & Workflows": "git branch pr pull merge commit diff sync pipeline workflow ci cd deploy release ship train",
        "AI & Agents": "ai agent llm model claude codex gemini chat room conversation voice think brain magic robot",
        "Bugs & Testing": "bug debug fix error crash issue test qa health doctor medical perf performance speed benchmark",
        "Design & Media": "design ui ux theme color colour paint style layout photo image camera video audio music sound voice game",
        "Devices & Hardware": "device iphone ipad mac macbook studio duo watch tv screen monitor display simulator hardware",
        "Systems & Web": "system server host cloud web browser internet network wifi dns domain storage disk drive relay",
        "Security & Keys": "security auth login password token secret key lock shield privacy permission admin",
        "Docs & Planning": "doc docs documentation readme book note write file folder plan task todo roadmap calendar time idea",
        "Charts & Commerce": "chart graph metric analytics data finance money billing stripe payment shop store legal bank",
        "People & Places": "person people user team group human chat support mail call office home work company",
        "Maps, Science & Travel": "map location gps travel flight car train bike boat science lab experiment research explore",
        "Nature & Food": "nature weather sun moon rain snow fire water plant animal dog cat rabbit bird coffee tea food drink",
        "Symbols & Awards": "symbol star heart crown trophy award win goal milestone flag bell alert pin help central command",
    ]

    /// Per-icon synonym keywords for common searches where the SF Symbol name differs.
    private static let iconKeywords: [String: String] = [
        "terminal.fill": "cli shell bash zsh console prompt command",
        "chevron.left.forwardslash.chevron.right": "code html xml tag jsx tsx",
        "command": "central command shortcut mac cmd headquarters hq",
        "cylinder.split.1x2.fill": "database db sql storage d1 postgres sqlite",
        "shippingbox.fill": "package release ship deploy box cargo artifact",
        "arrow.triangle.branch": "git branch fork tree repo",
        "arrow.triangle.pull": "git pull request pr",
        "arrow.triangle.merge": "git merge branch",
        "paperplane.fill": "send ship deploy launch publish telegram",
        "brain.head.profile": "ai agent mind memory thought",
        "bubble.left.and.bubble.right.fill": "chat room conversation group messages",
        "person.wave.2.fill": "voice speak talk assistant",
        "ladybug.fill": "bug debug issue defect",
        "stethoscope": "doctor diagnostics health check inspect",
        "gauge.with.dots.needle.67percent": "performance speed benchmark latency meter",
        "swatchpalette.fill": "theme tokens color colour design system",
        "paintpalette.fill": "theme art color colour palette",
        "safari.fill": "browser web page url",
        "building.columns.fill": "legal court bank institution governance",
        "square.stack.3d.up.fill": "artefact artifact stack layers",
        "cup.and.saucer.fill": "coffee tea break cafe",
        "mug.fill": "coffee beer drink",
        "hare.fill": "fast speed quick rabbit",
        "tortoise.fill": "slow turtle latency",
        "crown.fill": "owner admin king queen leader primary central",
        "shield.checkered": "command guard protection security",
    ]

    private let columns = [
        GridItem(.adaptive(minimum: 52, maximum: 64), spacing: 12),
    ]

    public init(
        sessionTitle: String,
        currentIcon: String?,
        onSelect: @escaping (String?) -> Void
    ) {
        self.sessionTitle = sessionTitle
        self.currentIcon = currentIcon
        self.onSelect = onSelect
    }

    public static func filteredSections(
        search: String,
        sectionFilter: String? = nil
    ) -> [(section: String, icons: [String])] {
        let base = sectionFilter == nil
            ? availableIcons
            : availableIcons.filter { $0.section == sectionFilter }
        let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return base }

        let tokens = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        var results: [(section: String, icons: [String])] = []
        var matchedIcons = Set<String>()

        for group in base {
            let groupWords = "\(group.section.lowercased()) \(sectionKeywords[group.section] ?? "")"
            let matching = group.icons.filter { icon in
                let searchable = "\(icon.lowercased().replacingOccurrences(of: ".", with: " ")) \(iconKeywords[icon] ?? "") \(groupWords)"
                return tokens.allSatisfy { searchable.contains($0) }
            }
            if !matching.isEmpty {
                results.append((section: group.section, icons: matching))
                matchedIcons.formUnion(matching)
            }
        }

        let candidateSymbol = trimmed.replacingOccurrences(of: " ", with: ".")
        if !matchedIcons.contains(candidateSymbol), isValidSystemSymbol(candidateSymbol) {
            results.append((section: "System Symbol", icons: [candidateSymbol]))
        }
        return results
    }

    public static func isValidSystemSymbol(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        #if canImport(UIKit)
        return UIImage(systemName: name) != nil
        #elseif canImport(AppKit)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
        #else
        return false
        #endif
    }

    private var visibleSections: [(section: String, icons: [String])] {
        Self.filteredSections(search: searchText, sectionFilter: selectedSection)
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    categoryStrip

                    let sections = visibleSections
                    if sections.isEmpty {
                        Text("No icons match “\(searchText)”.")
                            .font(.ripul(.subheadline))
                            .foregroundStyle(.ripul(.textSecondary))
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 32)
                            .uiKitIdentifier("SessionIconPicker.empty")
                    } else {
                        ForEach(sections, id: \.section) { group in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(group.section)
                                    .font(.ripul(.caption))
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.ripul(.textSecondary))
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
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
            .dismissesKeyboardOnTapAway()
            .searchable(text: $searchText, prompt: "Search icons or SF Symbol name")
            .navigationTitle("Icon for \(sessionTitle)")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .uiKitIdentifier("SessionIconPicker.cancelButton")
                }
                ToolbarItem(placement: .primaryAction) {
                    if currentIcon != nil {
                        Button("Remove") {
                            onSelect(nil)
                            dismiss()
                        }
                        .uiKitIdentifier("SessionIconPicker.removeButton")
                    }
                }
            }
        }
        #if os(iOS)
        .ripulSheet(.page, detents: [.medium, .large])
        #else
        .frame(minWidth: 460, minHeight: 520)
        #endif
    }

    private var categoryStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                categoryChip(title: "All", section: nil)
                ForEach(Self.availableIcons, id: \.section) { group in
                    categoryChip(title: group.section, section: group.section)
                }
            }
            .padding(.horizontal, 2)
        }
    }

    private func categoryChip(title: String, section: String?) -> some View {
        let isSelected = selectedSection == section
        return Button {
            selectedSection = isSelected ? nil : section
        } label: {
            Text(title)
                .font(.ripul(.caption, weight: .medium))
                .foregroundStyle(isSelected ? Color.ripul(.onAccent) : Color.ripul(.text))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(isSelected ? Color.accentColor : Color.ripul(.text).opacity(0.08))
                )
        }
        .buttonStyle(.plain)
        .uiKitIdentifier("SessionIconPicker.category.\(section ?? "All")")
    }

    private func iconButton(_ icon: String) -> some View {
        let isSelected = currentIcon == icon
        return Button {
            onSelect(icon)
            dismiss()
        } label: {
            Image(systemName: icon)
                .font(.ripulIcon(size: 22))
                .foregroundStyle(isSelected ? Color.ripul(.onAccent) : Color.ripul(.text))
                .frame(width: 48, height: 48)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(isSelected ? Color.accentColor : Color.ripul(.text).opacity(0.08))
                )
        }
        .buttonStyle(.plain)
        .uiKitIdentifier("SessionIconPicker.icon.\(icon)")
    }
}
