import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - CpuHudView
//
// Floating, draggable, RESIZABLE, always-on readout for the native CPU sampler.
// Watch native/system/web CPU + a sparkline while reproducing heat, average CPU
// over a marked window for A/B tests, and copy the stats out. Position, size and
// the threads-collapsed state persist across launches. Empty space around the
// card is not hit-tested, so touches fall through to the app behind it.
//
// Drag the header row to move; drag the bottom-right handle to resize.
@available(iOS 16.0, macOS 13.0, *)
public struct CpuHudView: View {
    @ObservedObject var sampler: CpuSampler

    // Persisted position + size (UserDefaults.standard via @AppStorage).
    @AppStorage("ripul.cpuHud.x") private var savedX = 0.0
    @AppStorage("ripul.cpuHud.y") private var savedY = 0.0
    @AppStorage("ripul.cpuHud.w") private var savedW = 260.0
    @AppStorage("ripul.cpuHud.h") private var savedH = 320.0
    @AppStorage("ripul.cpuHud.threadsExpanded") private var threadsExpanded = false

    @State private var offset = CGSize.zero
    @State private var dragStart = CGSize.zero
    @State private var size = CGSize(width: 260, height: 320)
    @State private var sizeAtDragStart: CGSize?
    @State private var didLoad = false
    @State private var justCopied = false

    public init(sampler: CpuSampler) {
        self.sampler = sampler
    }

    private func color(_ pct: Double) -> Color {
        if pct >= 80 { return .red }
        if pct >= 40 { return .orange }
        return .green
    }

    public var body: some View {
        // Fixed height only when the thread list is expanded; otherwise size to
        // content so a collapsed HUD is compact (not a tall empty card).
        Group {
            if threadsExpanded {
                card.frame(width: size.width, height: size.height)
            } else {
                card.frame(width: size.width)
            }
        }
        .offset(x: offset.width, y: offset.height)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(10)
        .onAppear {
            guard !didLoad else { return }
            offset = CGSize(width: savedX, height: savedY)
            dragStart = offset
            size = CGSize(width: savedW, height: savedH)
            didLoad = true
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            statsRows
            measurementSection
            Divider()
            threadDisclosure
            if threadsExpanded { threadList }
        }
        .padding(10)
        // Fill the fixed height only when expanded. When collapsed there is no
        // fixed height to fill, so maxHeight:.infinity would stretch the card to
        // the whole screen (and push the resize handle off-screen) — use nil so
        // it sizes to content instead.
        .frame(maxWidth: .infinity, maxHeight: threadsExpanded ? .infinity : nil, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(color(sampler.totalPercent).opacity(0.35), lineWidth: 1)
        )
        .overlay(resizeHandle, alignment: .bottomTrailing)
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
    }

    // Header doubles as the move handle.
    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Circle()
                .fill(color(sampler.totalPercent))
                .frame(width: 8, height: 8)
            Text(String(format: "%.0f%%", sampler.totalPercent))
                .font(.system(.title3, design: .monospaced).weight(.semibold))
                .foregroundStyle(color(sampler.totalPercent))
            Text("CPU")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            // Pause / resume sampling — freezes the readout and stops the 5Hz work.
            Button {
                if sampler.isRunning { sampler.stop() } else { sampler.start() }
            } label: {
                Image(systemName: sampler.isRunning ? "pause.circle" : "play.circle.fill")
                    .font(.body)
            }
            .buttonStyle(.plain)
            .foregroundStyle(sampler.isRunning ? Color.secondary : Color.green)
            Spacer(minLength: 6)
            sparkline
                .frame(width: 72, height: 22)
        }
        .contentShape(Rectangle())
        // .global coordinate space: translation is measured against the screen,
        // not the (moving) card, which prevents the drag-feedback oscillation.
        .gesture(
            DragGesture(coordinateSpace: .global)
                .onChanged { v in
                    offset = CGSize(width: dragStart.width + v.translation.width,
                                    height: dragStart.height + v.translation.height)
                }
                .onEnded { _ in
                    dragStart = offset
                    savedX = offset.width
                    savedY = offset.height
                }
        )
    }

    private var statsRows: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text("main")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(String(format: "%.0f%%", sampler.mainThreadPercent))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(color(sampler.mainThreadPercent))
                if let top = sampler.threads.first, !top.isMain {
                    Text("· \(top.name)")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            if sampler.systemAvailable {
                HStack(spacing: 8) {
                    Text("sys")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text(String(format: "%.0f%%", sampler.systemPercent))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(color(sampler.systemPercent))
                    Text("· web")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text(String(format: "%.0f%%", sampler.webOtherPercent))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(color(sampler.webOtherPercent))
                }
            }
        }
    }

    // Mark start / stop → average CPU over the window, + copy.
    private var measurementSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 12) {
                Button {
                    sampler.toggleMeasurement()
                } label: {
                    Label(sampler.isMeasuring ? "Stop & avg" : "Mark start",
                          systemImage: sampler.isMeasuring ? "stop.circle.fill" : "record.circle")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(sampler.isMeasuring ? Color.red : Color.accentColor)
                Spacer(minLength: 0)
                Button { copyStats() } label: {
                    Label(justCopied ? "Copied" : "Copy",
                          systemImage: justCopied ? "checkmark" : "doc.on.doc")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(justCopied ? Color.green : Color.secondary)
                Button { sampler.resetPeak() } label: {
                    Text("reset peak").font(.caption2)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
            if let m = sampler.measurement {
                VStack(alignment: .leading, spacing: 1) {
                    Text(String(format: "%@ %.1fs · %d samples",
                                sampler.isMeasuring ? "measuring" : "window", m.durationSec, m.samples))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text(String(format: "avg tot %.0f%% · main %.0f%% · peak %.0f%%",
                                m.avgTotal, m.avgMain, m.peakTotal))
                        .font(.system(.caption2, design: .monospaced))
                    if sampler.systemAvailable {
                        Text(String(format: "avg sys %.0f%% · web %.0f%%", m.avgSystem, m.avgWeb))
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // Collapsible thread breakdown (collapsed by default).
    private var threadDisclosure: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { threadsExpanded.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: threadsExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption2)
                Text("Threads (\(sampler.threads.count))")
                    .font(.system(.caption, design: .monospaced))
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // Scrollable so it fits whatever height the card is resized to.
    private var threadList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(sampler.threads.prefix(20)) { t in
                    HStack(spacing: 8) {
                        Text(t.name)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(t.isMain ? .primary : .secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 6)
                        Text(String(format: "%.0f%%", t.percent))
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(color(t.percent))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var resizeHandle: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.secondary)
            .padding(6)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(coordinateSpace: .global)
                    .onChanged { v in
                        if sizeAtDragStart == nil { sizeAtDragStart = size }
                        let base = sizeAtDragStart ?? size
                        size = CGSize(width: max(200, base.width + v.translation.width),
                                      height: max(160, base.height + v.translation.height))
                    }
                    .onEnded { _ in
                        sizeAtDragStart = nil
                        savedW = size.width
                        savedH = size.height
                    }
            )
    }

    // Normalized sparkline over the rolling history; scaled to max(100, recent peak).
    private var sparkline: some View {
        GeometryReader { geo in
            let data = sampler.history
            let maxV = max(100.0, data.max() ?? 100.0)
            Path { p in
                guard data.count > 1 else { return }
                let stepX = geo.size.width / CGFloat(data.count - 1)
                for (i, v) in data.enumerated() {
                    let x = CGFloat(i) * stepX
                    let y = geo.size.height * (1 - CGFloat(v / maxV))
                    if i == 0 { p.move(to: CGPoint(x: x, y: y)) }
                    else { p.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(color(sampler.totalPercent), lineWidth: 1.2)
        }
    }

    // MARK: - Copy

    private func copyStats() {
        let s = statsText()
        #if canImport(UIKit)
        UIPasteboard.general.string = s
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        #endif
        justCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { justCopied = false }
    }

    private func statsText() -> String {
        var lines: [String] = []
        lines.append(String(format: "CPU total %.0f%% · main %.0f%%",
                            sampler.totalPercent, sampler.mainThreadPercent))
        if sampler.systemAvailable {
            lines.append(String(format: "sys %.0f%% · web %.0f%%",
                                sampler.systemPercent, sampler.webOtherPercent))
        }
        if sampler.peakPercent > 0 {
            lines.append(String(format: "peak %.0f%% · %@", sampler.peakPercent, sampler.peakThreadName))
        }
        if let m = sampler.measurement {
            lines.append(String(format: "avg over %.1fs (%d samples): tot %.1f%% · main %.1f%% · sys %.1f%% · web %.1f%% · peak %.1f%%",
                                m.durationSec, m.samples, m.avgTotal, m.avgMain, m.avgSystem, m.avgWeb, m.peakTotal))
        }
        let threads = sampler.threads.prefix(10).map {
            String(format: "  %@ %.0f%%", $0.name, $0.percent)
        }
        if !threads.isEmpty {
            lines.append("threads:")
            lines.append(contentsOf: threads)
        }
        return lines.joined(separator: "\n")
    }
}
