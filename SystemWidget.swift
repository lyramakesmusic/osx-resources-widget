import SwiftUI
import AppKit
import Darwin

// MARK: - Formatting

func fmtRate(_ b: Double) -> String {
    if b < 1024 { return String(format: "%.0f B/s", b) }
    if b < 1_048_576 { return String(format: "%.1f KB/s", b / 1024) }
    if b < 1_073_741_824 { return String(format: "%.1f MB/s", b / 1_048_576) }
    return String(format: "%.2f GB/s", b / 1_073_741_824)
}

func fmtMem(_ b: Double) -> String {
    if b < 1_073_741_824 { return String(format: "%.0f MB", b / 1_048_576) }
    return String(format: "%.1f", b / 1_073_741_824)
}

// MARK: - System Stats

class SystemStats: ObservableObject {
    static let N = 60

    @Published var cpuHistory: [Double] = Array(repeating: 0, count: N)
    @Published var cpuUserHistory: [Double] = Array(repeating: 0, count: N)
    @Published var cpuSysHistory: [Double] = Array(repeating: 0, count: N)
    @Published var cpuUser: Double = 0
    @Published var cpuSys: Double = 0
    @Published var cpuIdle: Double = 100

    @Published var memHistory: [Double] = Array(repeating: 0, count: N)
    @Published var memUsed: Double = 0
    @Published var memTotal: Double = 0
    @Published var memApp: Double = 0
    @Published var memWired: Double = 0
    @Published var memCompressed: Double = 0

    @Published var netInHistory: [Double] = Array(repeating: 0, count: N)
    @Published var netOutHistory: [Double] = Array(repeating: 0, count: N)
    @Published var netInRate: Double = 0
    @Published var netOutRate: Double = 0

    private var timer: Timer?
    private var prevTicks: (u: UInt64, s: UInt64, i: UInt64, n: UInt64)?
    private var prevNetIn: UInt64 = 0
    private var prevNetOut: UInt64 = 0
    private var isFirst = true

    init() {
        let (bi, bo) = Self.networkBytes()
        prevNetIn = bi; prevNetOut = bo
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func tick() { tickCPU(); tickMem(); tickNet(); isFirst = false }

    func tickCPU() {
        var info: processor_info_array_t?
        var msgCount: mach_msg_type_number_t = 0
        var cpuCount: natural_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &msgCount) == KERN_SUCCESS,
              let p = info else { return }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: p), vm_size_t(Int(msgCount) * MemoryLayout<Int32>.stride)) }

        var tU: UInt64 = 0, tS: UInt64 = 0, tI: UInt64 = 0, tN: UInt64 = 0
        for c in 0..<Int(cpuCount) {
            let off = Int(CPU_STATE_MAX) * c
            tU += UInt64(UInt32(bitPattern: p[off + Int(CPU_STATE_USER)]))
            tS += UInt64(UInt32(bitPattern: p[off + Int(CPU_STATE_SYSTEM)]))
            tI += UInt64(UInt32(bitPattern: p[off + Int(CPU_STATE_IDLE)]))
            tN += UInt64(UInt32(bitPattern: p[off + Int(CPU_STATE_NICE)]))
        }
        if let prev = prevTicks {
            let dU = tU &- prev.u, dS = tS &- prev.s, dI = tI &- prev.i, dN = tN &- prev.n
            let total = dU &+ dS &+ dI &+ dN
            if total > 0 {
                cpuUser = Double(dU &+ dN) / Double(total) * 100
                cpuSys = Double(dS) / Double(total) * 100
                cpuIdle = Double(dI) / Double(total) * 100
                cpuUserHistory.append(cpuUser / 100)
                cpuSysHistory.append(cpuSys / 100)
                cpuHistory.append((cpuUser + cpuSys) / 100)
                if cpuHistory.count > Self.N { cpuHistory.removeFirst(); cpuUserHistory.removeFirst(); cpuSysHistory.removeFirst() }
            }
        }
        prevTicks = (tU, tS, tI, tN)
    }

    func tickMem() {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let r = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard r == KERN_SUCCESS else { return }
        let ps = Double(vm_kernel_page_size)
        memTotal = Double(ProcessInfo.processInfo.physicalMemory)
        let wired = Double(stats.wire_count) * ps
        let compressed = Double(stats.compressor_page_count) * ps
        let internal_ = Double(stats.internal_page_count) * ps
        let purgeable = Double(stats.purgeable_count) * ps
        memApp = max(0, internal_ - purgeable); memWired = wired; memCompressed = compressed
        memUsed = memApp + memWired + memCompressed
        memHistory.append(min(memUsed / memTotal, 1.0))
        if memHistory.count > Self.N { memHistory.removeFirst() }
    }

    static func networkBytes() -> (UInt64, UInt64) {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return (0, 0) }
        defer { freeifaddrs(ifaddr) }
        var tIn: UInt64 = 0, tOut: UInt64 = 0
        var cur = ifaddr
        while let ifa = cur {
            let a = ifa.pointee
            if a.ifa_addr != nil && a.ifa_addr.pointee.sa_family == UInt8(AF_LINK), let data = a.ifa_data {
                let d = data.assumingMemoryBound(to: if_data.self).pointee
                tIn += UInt64(d.ifi_ibytes); tOut += UInt64(d.ifi_obytes)
            }
            cur = a.ifa_next
        }
        return (tIn, tOut)
    }

    func tickNet() {
        let (bi, bo) = Self.networkBytes()
        if !isFirst {
            netInRate = Double(bi >= prevNetIn ? bi - prevNetIn : bi)
            netOutRate = Double(bo >= prevNetOut ? bo - prevNetOut : bo)
            netInHistory.append(netInRate); netOutHistory.append(netOutRate)
            if netInHistory.count > Self.N { netInHistory.removeFirst() }
            if netOutHistory.count > Self.N { netOutHistory.removeFirst() }
        }
        prevNetIn = bi; prevNetOut = bo
    }
}

// MARK: - Graph Drawing

struct AreaShape: Shape {
    let data: [Double]; let peak: Double
    func path(in rect: CGRect) -> Path {
        guard data.count > 1, peak > 0 else { return Path() }
        var p = Path()
        let dx = rect.width / CGFloat(data.count - 1)
        p.move(to: CGPoint(x: 0, y: rect.height))
        for (i, v) in data.enumerated() {
            p.addLine(to: CGPoint(x: CGFloat(i) * dx, y: rect.height * (1 - CGFloat(min(v / peak, 1.0)))))
        }
        p.addLine(to: CGPoint(x: CGFloat(data.count - 1) * dx, y: rect.height))
        p.closeSubpath()
        return p
    }
}

struct LineShape: Shape {
    let data: [Double]; let peak: Double
    func path(in rect: CGRect) -> Path {
        guard data.count > 1, peak > 0 else { return Path() }
        var p = Path()
        let dx = rect.width / CGFloat(data.count - 1)
        for (i, v) in data.enumerated() {
            let pt = CGPoint(x: CGFloat(i) * dx, y: rect.height * (1 - CGFloat(min(v / peak, 1.0))))
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        return p
    }
}

// Inset well for graphs
struct GraphWell<Content: View>: View {
    @Environment(\.colorScheme) var scheme
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        ZStack {
            content
        }
        .frame(height: 36)
        .padding(1)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.black.opacity(scheme == .dark ? 0.45 : 0.12))
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - Panels

struct CPUPanel: View {
    @ObservedObject var stats: SystemStats
    @Environment(\.colorScheme) var scheme
    var accent: Color { scheme == .dark ? Color(hue: 0.40, saturation: 0.50, brightness: 0.88) : .green }
    var sysClr: Color { scheme == .dark ? Color(hue: 0.08, saturation: 0.50, brightness: 0.92) : .orange }

    var body: some View {
        VStack(spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("CPU")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.85))
                Spacer()
                Text(String(format: "%.0f%%", stats.cpuUser + stats.cpuSys))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(accent)
            }
            .padding(.horizontal, 2)

            GraphWell {
                AreaShape(data: zip(stats.cpuUserHistory, stats.cpuSysHistory).map { $0 + $1 }, peak: 1.0)
                    .fill(LinearGradient(colors: [sysClr.opacity(0.45), sysClr.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                AreaShape(data: stats.cpuUserHistory, peak: 1.0)
                    .fill(LinearGradient(colors: [accent.opacity(0.5), accent.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                LineShape(data: stats.cpuHistory, peak: 1.0)
                    .stroke(accent.opacity(0.8), lineWidth: 1)
            }

            HStack(spacing: 6) {
                Circle().fill(accent.opacity(0.7)).frame(width: 4, height: 4)
                Text(String(format: "%.0f%% user", stats.cpuUser))
                Circle().fill(sysClr.opacity(0.7)).frame(width: 4, height: 4)
                Text(String(format: "%.0f%% sys", stats.cpuSys))
                Spacer()
            }
            .font(.system(size: 9)).foregroundStyle(.secondary)
            .padding(.horizontal, 2)
        }
    }
}

struct MemoryPanel: View {
    @ObservedObject var stats: SystemStats
    @Environment(\.colorScheme) var scheme
    var accent: Color {
        let f = stats.memTotal > 0 ? stats.memUsed / stats.memTotal : 0
        if scheme == .dark {
            if f < 0.5 { return Color(hue: 0.40, saturation: 0.45, brightness: 0.88) }
            if f < 0.7 { return .yellow }
            if f < 0.85 { return .orange }
            return .red
        } else {
            if f < 0.5 { return .green }
            if f < 0.7 { return .orange }
            if f < 0.85 { return .red }
            return .red
        }
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("Memory")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.85))
                Spacer()
                Text("\(fmtMem(stats.memUsed))/\(fmtMem(stats.memTotal)) GB")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(accent)
            }
            .padding(.horizontal, 2)

            GraphWell {
                AreaShape(data: stats.memHistory, peak: 1.0)
                    .fill(LinearGradient(colors: [accent.opacity(0.5), accent.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                LineShape(data: stats.memHistory, peak: 1.0)
                    .stroke(accent.opacity(0.8), lineWidth: 1)
            }

            HStack(spacing: 0) {
                Text("App ").foregroundStyle(.tertiary)
                Text(fmtMem(stats.memApp)).foregroundStyle(.secondary)
                Spacer()
                Text("Wire ").foregroundStyle(.tertiary)
                Text(fmtMem(stats.memWired)).foregroundStyle(.secondary)
                Spacer()
                Text("Cmp ").foregroundStyle(.tertiary)
                Text(fmtMem(stats.memCompressed)).foregroundStyle(.secondary)
            }
            .font(.system(size: 9, design: .monospaced))
            .padding(.horizontal, 2)
        }
    }
}

struct NetworkPanel: View {
    @ObservedObject var stats: SystemStats
    @Environment(\.colorScheme) var scheme
    var dnClr: Color { scheme == .dark ? .green : .indigo }
    var upClr: Color { scheme == .dark ? .red : .red }

    var peak: Double { max(stats.netInHistory.max() ?? 0, stats.netOutHistory.max() ?? 0, 1024) }

    var body: some View {
        VStack(spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("Network")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.85))
                Spacer()
            }
            .padding(.horizontal, 2)

            GraphWell {
                AreaShape(data: stats.netInHistory, peak: peak)
                    .fill(LinearGradient(colors: [dnClr.opacity(0.4), dnClr.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                LineShape(data: stats.netInHistory, peak: peak)
                    .stroke(dnClr.opacity(0.7), lineWidth: 1)
                AreaShape(data: stats.netOutHistory, peak: peak)
                    .fill(LinearGradient(colors: [upClr.opacity(0.3), upClr.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                LineShape(data: stats.netOutHistory, peak: peak)
                    .stroke(upClr.opacity(0.7), lineWidth: 1)
            }

            HStack {
                Image(systemName: "arrow.down").font(.system(size: 7, weight: .semibold)).foregroundStyle(dnClr.opacity(0.7))
                Text(fmtRate(stats.netInRate)).foregroundStyle(dnClr.opacity(0.7))
                Spacer()
                Image(systemName: "arrow.up").font(.system(size: 7, weight: .semibold)).foregroundStyle(upClr.opacity(0.7))
                Text(fmtRate(stats.netOutRate)).foregroundStyle(upClr.opacity(0.7))
            }
            .font(.system(size: 9, design: .monospaced))
            .padding(.horizontal, 2)
        }
    }
}

// MARK: - Widget Shell

struct WidgetView: View {
    @StateObject private var stats = SystemStats()
    @State private var isFloating = false
    @Environment(\.colorScheme) var scheme

    var body: some View {
        VStack(spacing: 0) {
            CPUPanel(stats: stats)
                .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 8)

            Rectangle().fill(.primary.opacity(0.08)).frame(height: 0.5)
                .padding(.horizontal, 16)

            MemoryPanel(stats: stats)
                .padding(.horizontal, 12).padding(.vertical, 8)

            Rectangle().fill(.primary.opacity(0.08)).frame(height: 0.5)
                .padding(.horizontal, 16)

            NetworkPanel(stats: stats)
                .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 12)
        }
        .frame(width: 230)
        .glassEffect(scheme == .dark ? .clear : .clear.tint(.white.opacity(0.92)),
                     in: .rect(cornerRadius: 22, style: .continuous))
        .contextMenu {
            Button(isFloating ? "Stick to Desktop" : "Float Above Windows") {
                isFloating.toggle()
                if let w = NSApplication.shared.windows.first {
                    if isFloating {
                        w.level = .floating
                        w.collectionBehavior = [.canJoinAllSpaces]
                    } else {
                        w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
                        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
                    }
                }
            }
            Divider()
            Button("Activity Monitor") {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
            }
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
    }
}

// MARK: - Always-active panel (prevents glass dimming on focus loss)

class WidgetPanel: NSPanel {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // Override private API — tells the glass compositor this window is "active"
    // Only force active in light mode; dark mode looks better with natural inactive blur
    @objc var _hasActiveAppearance: Bool {
        effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .aqua
    }
    @objc var hasKeyAppearance: Bool {
        effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .aqua
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: NSPanel!

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = WidgetPanel(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 320),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .transient]
        panel.isMovableByWindowBackground = true
        let hosting = NSHostingView(rootView: WidgetView())
        panel.contentView = hosting

        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: f.maxX - 270, y: f.maxY - 340))
        }
        panel.orderFrontRegardless()

        // When app loses focus, force glass back to active appearance
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.forceActiveGlass(self.panel.contentView)
                NotificationCenter.default.post(name: NSWindow.didBecomeMainNotification, object: self.panel)
                NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: self.panel)
            }
        }
    }

    /// Walk the view tree and force any NSVisualEffectView/NSGlassEffectView to active state
    func forceActiveGlass(_ view: NSView?) {
        guard let view = view else { return }
        if let vev = view as? NSVisualEffectView {
            vev.state = .active
        }
        // Try private API for glass effect views
        let sel = NSSelectorFromString("setState:")
        if view.className.contains("Glass"), view.responds(to: sel) {
            view.perform(sel, with: NSNumber(value: 1)) // 1 = active
        }
        for sub in view.subviews { forceActiveGlass(sub) }
    }
}

// MARK: - Entry

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
