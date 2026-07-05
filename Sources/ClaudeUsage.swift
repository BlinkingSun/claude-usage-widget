// Claude Usage — a small floating desktop "widget" for macOS that shows live
// Claude Code plan usage: the 5-hour session limit and the weekly limit, with
// reset countdowns, plus extra-usage credits. Companion to the Vitals widget.
//
// Data source: the same endpoint Claude Code's /usage screen uses —
//   GET https://api.anthropic.com/api/oauth/usage
// authorized with the Claude Code OAuth access token, which is read from the
// login Keychain item "Claude Code-credentials" via /usr/bin/security each
// poll (Claude Code refreshes that token itself whenever it's used, so
// re-reading every poll picks up rotations automatically).
//
// No Xcode project / app-extension needed: compiled with swiftc, ad-hoc signed.

import SwiftUI
import AppKit

// MARK: - Color helpers ------------------------------------------------------

enum Threshold {
    /// Green below `warn`, yellow up to `crit`, red at/above `crit`.
    static func color(_ v: Double, warn: Double, crit: Double) -> Color {
        if v >= crit { return Color(red: 0.95, green: 0.26, blue: 0.21) }   // red
        if v >= warn { return Color(red: 0.98, green: 0.75, blue: 0.18) }   // yellow
        return Color(red: 0.30, green: 0.85, blue: 0.39)                    // green
    }
}

// MARK: - API response --------------------------------------------------------

struct LimitBucket: Decodable {
    let utilization: Double?        // 0…100 (percent)
    let resets_at: String?          // ISO8601 with fractional seconds, or null
}

struct ExtraUsage: Decodable {
    let is_enabled: Bool?
    let monthly_limit: Double?      // USD
    let used_credits: Double?       // USD
}

struct UsageResponse: Decodable {
    let five_hour: LimitBucket?
    let seven_day: LimitBucket?
    let seven_day_opus: LimitBucket?
    let seven_day_sonnet: LimitBucket?
    let extra_usage: ExtraUsage?
}

enum FetchError: Error {
    case noToken
    case http(Int)
    case network(String)
    case parse

    var message: String {
        switch self {
        case .noToken:      return "No Claude Code login found in Keychain"
        case .http(401), .http(403):
                            return "Sign-in expired — use Claude Code once to refresh"
        case .http(let c):  return "Server error (HTTP \(c))"
        case .network(let m): return m
        case .parse:        return "Unexpected response format"
        }
    }
}

// MARK: - Usage model ---------------------------------------------------------

final class Usage: ObservableObject {
    @Published var sessionFrac: Double? = nil   // 0…1
    @Published var sessionResets: Date? = nil
    @Published var weekFrac: Double? = nil      // 0…1
    @Published var weekResets: Date? = nil
    @Published var opusFrac: Double? = nil      // weekly, per-model (when present)
    @Published var sonnetFrac: Double? = nil
    @Published var extraEnabled = false
    @Published var extraUsed: Double = 0        // USD
    @Published var extraLimit: Double = 0       // USD

    @Published var lastUpdate: Date? = nil
    @Published var errorText: String? = nil
    @Published var now = Date()                 // 1 s tick so countdowns stay live

    // History (0…1) for sparklines — one sample per poll (60 s ≈ 48 min window)
    @Published var sessionHist: [Double] = []
    private let histLen = 48

    private var pollTimer: Timer?
    private var tickTimer: Timer?

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    init() {
        fetch()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.fetch()
        }
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.now = Date()
        }
    }

    static func parseDate(_ s: String?) -> Date? {
        guard let s = s else { return nil }
        return iso.date(from: s) ?? isoPlain.date(from: s)
    }

    func fetch() {
        DispatchQueue.global(qos: .utility).async {
            let result = Self.fetchUsage()
            DispatchQueue.main.async { self.apply(result) }
        }
    }

    private func apply(_ result: Result<UsageResponse, FetchError>) {
        switch result {
        case .failure(let e):
            errorText = e.message      // keep showing the last good numbers
        case .success(let r):
            errorText = nil
            lastUpdate = Date()
            func frac(_ b: LimitBucket?) -> Double? {
                guard let u = b?.utilization else { return nil }
                return max(0, min(1, u / 100))
            }
            sessionFrac   = frac(r.five_hour)
            sessionResets = Self.parseDate(r.five_hour?.resets_at)
            weekFrac      = frac(r.seven_day)
            weekResets    = Self.parseDate(r.seven_day?.resets_at)
            opusFrac      = frac(r.seven_day_opus)
            sonnetFrac    = frac(r.seven_day_sonnet)
            extraEnabled  = r.extra_usage?.is_enabled ?? false
            // The usage API returns extra-usage amounts in CENTS — convert to dollars.
            extraUsed     = (r.extra_usage?.used_credits ?? 0) / 100
            extraLimit    = (r.extra_usage?.monthly_limit ?? 0) / 100
            if let s = sessionFrac {
                sessionHist.append(s)
                if sessionHist.count > histLen { sessionHist.removeFirst(sessionHist.count - histLen) }
            }
        }
    }

    // MARK: token + request (called on a background queue)

    /// Read the Claude Code OAuth access token from the login Keychain.
    /// Uses /usr/bin/security (already on the item's ACL) rather than
    /// SecItemCopyMatching so the ad-hoc re-signed app never re-triggers
    /// a Keychain permission prompt after rebuilds.
    private static func readToken() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String
        else { return nil }
        return token
    }

    private static func fetchUsage() -> Result<UsageResponse, FetchError> {
        guard let token = readToken() else { return .failure(.noToken) }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.timeoutInterval = 15
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var result: Result<UsageResponse, FetchError> = .failure(.network("No response"))
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, resp, err in
            defer { sem.signal() }
            if let err = err {
                result = .failure(.network(err.localizedDescription))
                return
            }
            guard let http = resp as? HTTPURLResponse else {
                result = .failure(.network("No response"))
                return
            }
            guard http.statusCode == 200 else {
                result = .failure(.http(http.statusCode))
                return
            }
            guard let data = data,
                  let parsed = try? JSONDecoder().decode(UsageResponse.self, from: data)
            else {
                result = .failure(.parse)
                return
            }
            result = .success(parsed)
        }.resume()
        sem.wait()
        return result
    }
}

// MARK: - Formatting ---------------------------------------------------------

/// "3h 41m", "2d 4h", "12m" — or "—" when unknown / already past.
func fmtCountdown(to date: Date?, from now: Date) -> String {
    guard let date = date else { return "—" }
    let s = date.timeIntervalSince(now)
    guard s > 0 else { return "now" }
    let m = Int(s / 60)
    if m >= 48 * 60 { return "\(m / 1440)d \((m % 1440) / 60)h" }
    if m >= 60 { return "\(m / 60)h \(m % 60)m" }
    return "\(max(1, m))m"
}

/// Absolute reset moment: "5:20 AM" if today/tomorrow-ish, else "Fri 9:00 PM".
func fmtResetTime(_ date: Date?) -> String {
    guard let date = date else { return "—" }
    let f = DateFormatter()
    f.dateFormat = date.timeIntervalSinceNow < 22 * 3600 ? "h:mm a" : "EEE h:mm a"
    return f.string(from: date)
}

func fmtUSD(_ v: Double) -> String {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    f.minimumFractionDigits = 2      // always show cents, e.g. $271.75 / $350.00
    f.maximumFractionDigits = 2
    return "$" + (f.string(from: NSNumber(value: v)) ?? "0.00")
}

func fmtAgo(_ date: Date?, now: Date) -> String {
    guard let date = date else { return "never" }
    let s = Int(now.timeIntervalSince(date))
    if s < 5 { return "just now" }
    if s < 90 { return "\(s)s ago" }
    return "\(s / 60)m ago"
}

// MARK: - Small views --------------------------------------------------------

struct Ring: View {
    let fraction: Double
    let color: Color
    var line: CGFloat = 6
    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.12), lineWidth: line)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, fraction)))
                .stroke(color, style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.4), value: fraction)
        }
    }
}

struct Sparkline: View {
    let data: [Double]          // 0…1
    let color: Color
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                if data.count > 1 {
                    let pts = data.enumerated().map { i, v in
                        CGPoint(x: w * CGFloat(i) / CGFloat(data.count - 1),
                                y: h - CGFloat(max(0, min(1, v))) * h)
                    }
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: h))
                        p.addLine(to: pts[0])
                        pts.dropFirst().forEach { p.addLine(to: $0) }
                        p.addLine(to: CGPoint(x: w, y: h))
                        p.closeSubpath()
                    }.fill(color.opacity(0.18))
                    Path { p in
                        p.move(to: pts[0])
                        pts.dropFirst().forEach { p.addLine(to: $0) }
                    }.stroke(color, style: StrokeStyle(lineWidth: 1.3, lineJoin: .round))
                }
            }
        }
    }
}

/// One usage-limit ring: % used in the middle, countdown-to-reset underneath.
struct LimitRing: View {
    let title: String
    let frac: Double?           // nil = no data yet
    let resetsAt: Date?
    let now: Date

    var body: some View {
        let f = frac ?? 0
        let color = frac == nil ? Color.secondary : Threshold.color(f, warn: 0.70, crit: 0.90)
        VStack(spacing: 3) {
            ZStack {
                Ring(fraction: f, color: color)
                VStack(spacing: -1) {
                    Text(frac == nil ? "–" : "\(Int((f * 100).rounded()))%")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                    Text(fmtCountdown(to: resetsAt, from: now))
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 54, height: 54)
            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("↻ \(fmtResetTime(resetsAt))")
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
        }
    }
}

struct BarMetric: View {
    let title: String
    let frac: Double
    let detail: String
    let warn: Double
    let crit: Double
    var body: some View {
        let color = Threshold.color(frac, warn: warn, crit: crit)
        VStack(spacing: 2) {
            HStack {
                Text(title).font(.system(size: 9, weight: .semibold))
                Spacer()
                Text(detail).font(.system(size: 9)).foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12))
                    Capsule().fill(color)
                        .frame(width: max(2, geo.size.width * CGFloat(max(0, min(1, frac)))))
                        .animation(.easeOut(duration: 0.4), value: frac)
                }
            }
            .frame(height: 6)
        }
    }
}

// MARK: - Root widget view ---------------------------------------------------

struct WidgetView: View {
    @ObservedObject var usage: Usage
    @ObservedObject var app: AppState

    // Same footprint as Vitals / the macOS small desktop widgets: a 180×180 pt
    // window whose visible rounded panel is inset 8 pt (164 pt) at 24 pt radius.
    private let windowSize: CGFloat = 180
    private let panelMargin: CGFloat = 8
    private let panelRadius: CGFloat = 24

    var body: some View {
        VStack(spacing: 9) {
            HStack(alignment: .top, spacing: 14) {
                LimitRing(title: "SESSION", frac: usage.sessionFrac,
                          resetsAt: usage.sessionResets, now: usage.now)
                LimitRing(title: "WEEK", frac: usage.weekFrac,
                          resetsAt: usage.weekResets, now: usage.now)
            }
            if usage.extraEnabled, usage.extraLimit > 0 {
                BarMetric(title: "EXTRA",
                          frac: usage.extraUsed / usage.extraLimit,
                          detail: "\(fmtUSD(usage.extraUsed)) / \(fmtUSD(usage.extraLimit))",
                          warn: 0.70, crit: 0.90)
            }
            HStack(spacing: 4) {
                Circle()
                    .fill(usage.errorText == nil ? Color(red: 0.30, green: 0.85, blue: 0.39)
                                                 : Color(red: 0.98, green: 0.75, blue: 0.18))
                    .frame(width: 5, height: 5)
                Text("claude · \(fmtAgo(usage.lastUpdate, now: usage.now))")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
            }

            if app.expanded {
                Divider().opacity(0.4)
                DetailView(usage: usage)
            }
        }
        .padding(10)
        .frame(width: windowSize - 2 * panelMargin,
               height: app.expanded ? nil : windowSize - 2 * panelMargin)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: panelRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: panelRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: panelRadius, style: .continuous))
        .padding(panelMargin)
        .onTapGesture { app.toggleExpand() }
        .gesture(
            DragGesture(minimumDistance: 4)
                .onChanged { _ in
                    // Track the absolute mouse position in screen coordinates
                    // (see Vitals: window-relative deltas oscillate while the
                    // window itself moves).
                    app.dragToMouse()
                }
                .onEnded { _ in app.endDrag() }
        )
        .contextMenu {
            Button(app.expanded ? "Collapse" : "Expand") { app.toggleExpand() }
            Button("Refresh Now") { usage.fetch() }
            Toggle("Launch at Login", isOn: Binding(
                get: { app.launchAtLogin },
                set: { app.setLaunchAtLogin($0) }))
            Divider()
            Button("Quit Claude Usage") { NSApp.terminate(nil) }
        }
    }
}

struct DetailRow: View {
    let label: String
    let value: String
    var color: Color = .primary
    var body: some View {
        HStack {
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.system(size: 9, weight: .medium)).foregroundStyle(color)
        }
    }
}

struct DetailView: View {
    @ObservedObject var usage: Usage
    var body: some View {
        VStack(spacing: 4) {
            if let s = usage.sessionFrac {
                DetailRow(label: "Session (5 h)",
                          value: "\(Int((s * 100).rounded()))% · resets \(fmtResetTime(usage.sessionResets))",
                          color: Threshold.color(s, warn: 0.70, crit: 0.90))
            }
            if let w = usage.weekFrac {
                DetailRow(label: "Week (all models)",
                          value: "\(Int((w * 100).rounded()))% · resets \(fmtResetTime(usage.weekResets))",
                          color: Threshold.color(w, warn: 0.70, crit: 0.90))
            }
            if let o = usage.opusFrac {
                DetailRow(label: "Week · Opus", value: "\(Int((o * 100).rounded()))%")
            }
            if let so = usage.sonnetFrac {
                DetailRow(label: "Week · Sonnet", value: "\(Int((so * 100).rounded()))%")
            }
            if usage.extraEnabled {
                DetailRow(label: "Extra usage",
                          value: "\(fmtUSD(usage.extraUsed)) of \(fmtUSD(usage.extraLimit))")
            }
            Divider().opacity(0.3)
            DetailRow(label: "Updated", value: fmtAgo(usage.lastUpdate, now: usage.now))
            if let e = usage.errorText {
                Text(e)
                    .font(.system(size: 8))
                    .foregroundStyle(Color(red: 0.98, green: 0.75, blue: 0.18))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Sparkline(data: usage.sessionHist,
                      color: Threshold.color(usage.sessionFrac ?? 0, warn: 0.70, crit: 0.90))
                .frame(height: 16)
                .padding(.top, 2)
        }
    }
}

// MARK: - App / window glue --------------------------------------------------

final class AppState: ObservableObject {
    @Published var expanded = false
    @Published var launchAtLogin = false
    weak var window: NSPanel?
    weak var hosting: NSView?

    init() {
        launchAtLogin = isLaunchAgentInstalled()
    }

    func toggleExpand() {
        expanded.toggle()
        DispatchQueue.main.async { self.resizeToFit(animated: true) }
    }

    func resizeToFit(animated: Bool) {
        guard let w = window, let h = hosting else { return }
        let top = w.frame.maxY
        let size = h.fittingSize
        var f = w.frame
        f.size = size
        f.origin.y = top - size.height          // keep the top edge anchored
        w.setFrame(f, display: true, animate: animated)
    }

    private var dragGrabOffset: CGSize?

    func dragToMouse() {
        guard let w = window else { return }
        let mouse = NSEvent.mouseLocation
        let origin = w.frame.origin
        if dragGrabOffset == nil {
            dragGrabOffset = CGSize(width: mouse.x - origin.x,
                                    height: mouse.y - origin.y)
        }
        guard let off = dragGrabOffset else { return }
        w.setFrameOrigin(NSPoint(x: (mouse.x - off.width).rounded(),
                                 y: (mouse.y - off.height).rounded()))
    }

    func endDrag() {
        dragGrabOffset = nil
        window?.saveFrame(usingName: "ClaudeUsageWidgetFrame")
    }

    // Launch-at-login via a per-user LaunchAgent (reliable for ad-hoc-signed apps).
    private let agentLabel = "com.claudeusagewidget.mac"

    private var agentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
    }

    func isLaunchAgentInstalled() -> Bool {
        FileManager.default.fileExists(atPath: agentURL.path)
    }

    func setLaunchAtLogin(_ on: Bool) {
        if on {
            guard let exe = Bundle.main.executablePath else { return }
            let plist: [String: Any] = [
                "Label": agentLabel,
                "ProgramArguments": [exe],
                "RunAtLoad": true,
                "ProcessType": "Interactive",
                "LimitLoadToSessionType": "Aqua",
            ]
            do {
                try FileManager.default.createDirectory(
                    at: agentURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                let data = try PropertyListSerialization.data(
                    fromPropertyList: plist, format: .xml, options: 0)
                try data.write(to: agentURL)
            } catch {
                NSLog("ClaudeUsage: could not install LaunchAgent: \(error)")
            }
        } else {
            try? FileManager.default.removeItem(at: agentURL)
        }
        launchAtLogin = isLaunchAgentInstalled()
    }
}

final class WidgetPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let usage = Usage()
    let appState = AppState()
    var panel: WidgetPanel?

    func applicationDidFinishLaunching(_ note: Notification) {
        let root = WidgetView(usage: usage, app: appState)
        let hosting = NSHostingView(rootView: root)
        hosting.setFrameSize(hosting.fittingSize)

        let panel = WidgetPanel(
            contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.contentView = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .normal              // not pinned on top — other windows can cover it
        panel.isFloatingPanel = false
        // .fullScreenNone keeps the widget off full-screen Spaces — without it a
        // nonactivating panel that joins all Spaces also floats over full-screen apps.
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenNone]
        panel.isMovableByWindowBackground = false   // we drag manually
        panel.hidesOnDeactivate = false

        appState.window = panel
        appState.hosting = hosting
        self.panel = panel

        // Restore saved position, else default just below where Vitals defaults
        // (upper-right of the main screen) so the two widgets stack neatly.
        panel.setFrameAutosaveName("ClaudeUsageWidgetFrame")
        if panel.frame.origin == .zero, let screen = NSScreen.main {
            let vf = screen.visibleFrame
            let size = hosting.fittingSize
            panel.setFrameOrigin(NSPoint(x: vf.maxX - size.width - 20,
                                         y: vf.maxY - size.height - 20 - 190))
        }
        panel.orderFrontRegardless()

        // On the very first launch, enable auto-start at login.
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: "ClaudeUsageDidConfigureLogin") {
            appState.setLaunchAtLogin(true)
            defaults.set(true, forKey: "ClaudeUsageDidConfigureLogin")
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }
}

// MARK: - Entry point --------------------------------------------------------

@main
enum ClaudeUsage {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)     // no Dock icon — it's a widget
        app.run()
    }
}
