import SwiftUI
import AppKit
import Carbon
import ServiceManagement

// Secondary text: system gray in dark; darker in light, where the vibrant
// ~50% gray over the white popover backing reads as washed out.
extension Color {
    static let secondaryText = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? .secondaryLabelColor
            : NSColor(white: 0.24, alpha: 1.0)
    })
}

/// Compact choice control with the accent-blue selection of the app's prominent buttons.
struct ChoicePills: View {
    @Binding var selection: String
    let options: [(label: String, tag: String)]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.tag) { option in
                let selected = selection == option.tag
                Button(action: { selection = option.tag }) {
                    Text(option.label)
                        .font(.caption)
                        .fontWeight(selected ? .semibold : .regular)
                        .foregroundColor(selected ? .white : Color.secondaryText)
                        .frame(minWidth: 58)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 5).fill(selected ? Color.accentColor : Color.clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.secondary.opacity(0.15)))
        .fixedSize()
    }
}

struct PaceMarker {
    let expected: Double   // 0...1
    let tooltip: String
}

struct UsageBar: View {
    let value: Double
    let color: Color
    var pace: PaceMarker? = nil

    @State private var isHovering = false
    private let tickWidth: CGFloat = 1.5

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule()
                    .fill(color)
                    .frame(width: max(0, min(1, value)) * geo.size.width)
                if let pace = pace {
                    Rectangle()
                        .fill(Color.primary.opacity(0.7))
                        .frame(width: tickWidth)
                        .offset(x: max(0, min(1, pace.expected)) * geo.size.width - tickWidth / 2)
                }
            }
            .clipShape(Capsule())
            .overlay(alignment: .topLeading) {
                if let pace = pace, isHovering {
                    PaceTooltip(text: pace.tooltip)
                        .offset(y: -24)
                }
            }
        }
        .frame(height: 6)
        .onHover { isHovering = $0 }
    }
}

struct PaceTooltip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2)
            .foregroundColor(Color.primary)
            .fixedSize()
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(0.28), radius: 3, y: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
            )
            .allowsHitTesting(false)
    }
}

// MARK: - Data Models

struct ModelQuotaItem: Identifiable, Equatable {
    let id: String          // modelId or family key
    let label: String       // e.g. "Gemini 4 Argon" or "Gemini 4 Argon (Medium)"
    let family: String      // e.g. "Gemini 4 Argon"
    let usedFraction: Double // 0.0 ... 1.0 (1.0 - remainingFraction)
    let remainingFraction: Double
    let resetTime: Date?
    let isActiveModel: Bool
    let tagTitle: String?
    let windowSeconds: TimeInterval // 5h (18000) or 7d (604800)

    var usedPercentageInt: Int {
        Int((usedFraction * 100).rounded())
    }
}

struct LocalTokenStats: Equatable {
    var sessionCount: Int = 0
    var stepCount: Int = 0
    var todayInputTokens: Int = 0
    var todayCacheTokens: Int = 0
    var todayOutputTokens: Int = 0
    var totalInputTokens: Int = 0
    var totalCacheTokens: Int = 0
    var totalOutputTokens: Int = 0

    var todayTotal: Int { todayInputTokens + todayOutputTokens }
    var lifetimeTotal: Int { totalInputTokens + totalOutputTokens }
}

// MARK: - Pace

enum PaceWindow {
    static let fiveHour: TimeInterval = 5 * 3600
    static let weekly: TimeInterval = 7 * 24 * 3600

    static func infer(from resetsAt: Date?, now: Date = Date()) -> TimeInterval {
        guard let resetsAt = resetsAt else { return fiveHour }
        let remaining = resetsAt.timeIntervalSince(now)
        if remaining > 6 * 3600 {
            return weekly
        }
        return fiveHour
    }
}

struct Pace {
    let expected: Double
    let elapsed: TimeInterval

    init?(resetsAt: Date?, window: TimeInterval, now: Date = Date()) {
        guard let resetsAt = resetsAt, window > 0, now < resetsAt else { return nil }
        let elapsed = now.timeIntervalSince(resetsAt.addingTimeInterval(-window))
        guard elapsed >= 0 else { return nil }
        self.expected = min(1, max(0, elapsed / window))
        self.elapsed = elapsed
    }
}

// MARK: - AppDelegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var popover: NSPopover!
    var usageManager: UsageManager!
    var eventMonitor: Any?
    var hotKeyRef: EventHotKeyRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("✅ AntigravityUsageBar launched")

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            updateStatusIcon(percentage: 0, connected: false)
            button.action = #selector(handleClick)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.target = self
            button.appearsDisabled = false
            button.isEnabled = true
        }

        usageManager = UsageManager(statusItem: statusItem, delegate: self)

        popover = NSPopover()
        popover.contentSize = NSSize(width: 370, height: 360)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: UsageView(
            usageManager: usageManager
        ))

        applyAppearancePreference()

        DistributedNotificationCenter.default.addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self?.applyAppearancePreference()
            }
        }

        // Initial fetch
        usageManager.fetchUsage()

        // Poll every 60 seconds (local language_server is instant and lightweight)
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.usageManager.fetchUsage()
        }

        setupKeyboardShortcut()
    }

    func applyAppearancePreference() {
        let mode = UserDefaults.standard.string(forKey: "agy_appearance_mode") ?? "system"
        let systemIsDark = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
        let isDark: Bool
        switch mode {
        case "dark":  isDark = true
        case "light": isDark = false
        default:      isDark = systemIsDark
        }
        let appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        NSApp.appearance = appearance
        popover?.appearance = appearance
    }

    func setupKeyboardShortcut() {
        checkAccessibilityPermissions()
        if usageManager.shortcutEnabled {
            registerGlobalHotKey()
        }
    }

    func setShortcutEnabled(_ enabled: Bool) {
        if enabled {
            registerGlobalHotKey()
        } else {
            unregisterGlobalHotKey()
        }
    }

    func checkAccessibilityPermissions() {
        let trusted = AXIsProcessTrusted()
        if !trusted {
            NSLog("⚠️ Accessibility permissions not granted")
        }
    }

    func registerGlobalHotKey() {
        if hotKeyRef != nil { return }

        var hotKeyID = EventHotKeyID()
        hotKeyID.signature = 0x41675542 // 'AgUB'
        hotKeyID.id = 1

        let keyCode: UInt32 = 32 // 'U' key
        let modifiers: UInt32 = UInt32(cmdKey | shiftKey) // Cmd+Shift+U (avoids conflict with ClaudeUsageBar Cmd+U)

        var eventType = EventTypeSpec()
        eventType.eventClass = OSType(kEventClassKeyboard)
        eventType.eventKind = OSType(kEventHotKeyPressed)

        var handler: EventHandlerRef?
        let callback: EventHandlerUPP = { (_, _, userData) -> OSStatus in
            let appDelegate = Unmanaged<AppDelegate>.fromOpaque(userData!).takeUnretainedValue()
            DispatchQueue.main.async {
                appDelegate.togglePopover()
            }
            return noErr
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &eventType, selfPtr, &handler)

        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        if status == noErr {
            NSLog("✅ Registered Cmd+Shift+U hotkey successfully")
        }
    }

    func unregisterGlobalHotKey() {
        if let hotKey = hotKeyRef {
            UnregisterEventHotKey(hotKey)
            hotKeyRef = nil
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        unregisterGlobalHotKey()
    }

    @objc func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    @objc func togglePopover() {
        if popover.isShown {
            closePopover()
        } else {
            openPopover()
        }
    }

    @objc func handleClick() {
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseUp {
            let menu = NSMenu()
            let toggleItem = NSMenuItem(title: "Toggle Antigravity Usage (⌘⇧U)", action: #selector(togglePopover), keyEquivalent: "U")
            toggleItem.keyEquivalentModifierMask = [.command, .shift]
            menu.addItem(toggleItem)
            menu.addItem(NSMenuItem(title: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r"))
            menu.addItem(NSMenuItem.separator())
            menu.addItem(NSMenuItem(title: "Quit AntigravityUsageBar", action: #selector(quitApp), keyEquivalent: "q"))
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            togglePopover()
        }
    }

    @objc func refreshNow() {
        usageManager.fetchUsage()
    }

    func openPopover() {
        if let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                if self?.popover.isShown == true {
                    self?.closePopover()
                }
            }
        }
    }

    func closePopover() {
        popover.performClose(nil)
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    func updateStatusIcon(percentage: Int, connected: Bool = true) {
        guard let button = statusItem.button else { return }

        let color: NSColor
        if !connected {
            color = NSColor.systemGray
        } else if percentage < 70 {
            color = NSColor(red: 0.13, green: 0.77, blue: 0.37, alpha: 1.0) // Green
        } else if percentage < 90 {
            color = NSColor(red: 1.0, green: 0.8, blue: 0.0, alpha: 1.0) // Yellow
        } else {
            color = NSColor(red: 1.0, green: 0.23, blue: 0.19, alpha: 1.0) // Red
        }

        let icon = createAntigravityIcon(color: color)
        button.image = icon
        button.title = connected ? " \(percentage)%" : " --%"
    }

    func createAntigravityIcon(color: NSColor) -> NSImage {
        let size = NSSize(width: 16, height: 16)
        let image = NSImage(size: size)

        image.lockFocus()

        // Stylized Antigravity diamond/sparkle rocket icon
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 8, y: 1))
        path.line(to: NSPoint(x: 9.5, y: 6))
        path.line(to: NSPoint(x: 15, y: 8))
        path.line(to: NSPoint(x: 9.5, y: 10))
        path.line(to: NSPoint(x: 8, y: 15))
        path.line(to: NSPoint(x: 6.5, y: 10))
        path.line(to: NSPoint(x: 1, y: 8))
        path.line(to: NSPoint(x: 6.5, y: 6))
        path.close()

        color.setFill()
        path.fill()

        // Small orbital dot
        let dot = NSBezierPath(ovalIn: NSRect(x: 11.5, y: 11.5, width: 3, height: 3))
        color.setFill()
        dot.fill()

        image.unlockFocus()
        image.isTemplate = false

        return image
    }
}

// Allow self-signed localhost TLS from language_server if needed
class LocalServerSessionDelegate: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           challenge.protectionSpace.host == "127.0.0.1" || challenge.protectionSpace.host == "localhost",
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

// MARK: - Main Entry Point

@main
struct Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

// MARK: - UsageManager

class UsageManager: ObservableObject {
    @Published var userName: String = ""
    @Published var userEmail: String = ""
    @Published var tierName: String = "Antigravity"
    @Published var planName: String = ""

    @Published var availablePromptCredits: Int = 0
    @Published var monthlyPromptCredits: Int = 0
    @Published var availableFlowCredits: Int = 0
    @Published var monthlyFlowCredits: Int = 0

    @Published var modelGroups: [ModelQuotaItem] = []
    @Published var allModels: [ModelQuotaItem] = []
    @Published var activeModelLabel: String = ""
    @Published var primaryPercentage: Int = 0

    @Published var localStats: LocalTokenStats = LocalTokenStats()
    @Published var serverConnected: Bool = false
    @Published var detectedPort: Int = 0
    @Published var detectedPid: Int = 0

    @Published var lastUpdated: Date = Date()
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    @Published var hasFetchedData: Bool = false

    // Settings
    @Published var usageNotificationsEnabled: Bool = true
    @Published var openAtLogin: Bool = false
    @Published var isAccessibilityEnabled: Bool = false
    @Published var shortcutEnabled: Bool = true
    @Published var paceMarkerEnabled: Bool = false
    @Published var groupModelsByFamily: Bool = true
    @Published var menuBarMetric: String = "active" // "active" | "highest" | "gemini" | "claude"
    @Published var manualPort: String = ""
    @Published var manualCsrfToken: String = ""

    private var statusItem: NSStatusItem?
    private weak var delegate: AppDelegate?
    private var lastNotifiedThreshold: Int = 0
    private lazy var urlSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 4.0
        return URLSession(configuration: config, delegate: LocalServerSessionDelegate(), delegateQueue: nil)
    }()

    init(statusItem: NSStatusItem?, delegate: AppDelegate? = nil) {
        self.statusItem = statusItem
        self.delegate = delegate
        loadSettings()
        checkAccessibilityStatus()
    }

    func checkAccessibilityStatus() {
        isAccessibilityEnabled = AXIsProcessTrusted()
    }

    func loadSettings() {
        let d = UserDefaults.standard
        if d.object(forKey: "agy_usage_notifications") == nil {
            usageNotificationsEnabled = true
        } else {
            usageNotificationsEnabled = d.bool(forKey: "agy_usage_notifications")
        }

        if #available(macOS 13.0, *) {
            openAtLogin = (SMAppService.mainApp.status == .enabled)
        } else {
            openAtLogin = d.bool(forKey: "agy_open_at_login")
        }

        lastNotifiedThreshold = d.integer(forKey: "agy_last_notified_threshold")
        shortcutEnabled = d.object(forKey: "agy_shortcut_enabled") == nil ? true : d.bool(forKey: "agy_shortcut_enabled")
        paceMarkerEnabled = d.bool(forKey: "agy_pace_marker_enabled")
        groupModelsByFamily = d.object(forKey: "agy_group_models") == nil ? true : d.bool(forKey: "agy_group_models")
        menuBarMetric = d.string(forKey: "agy_menubar_metric") ?? "active"
        manualPort = d.string(forKey: "agy_manual_port") ?? ""
        manualCsrfToken = d.string(forKey: "agy_manual_csrf") ?? ""
    }

    func saveSettings() {
        let d = UserDefaults.standard
        d.set(usageNotificationsEnabled, forKey: "agy_usage_notifications")
        d.set(openAtLogin, forKey: "agy_open_at_login")
        d.set(shortcutEnabled, forKey: "agy_shortcut_enabled")
        d.set(paceMarkerEnabled, forKey: "agy_pace_marker_enabled")
        d.set(groupModelsByFamily, forKey: "agy_group_models")
        d.set(menuBarMetric, forKey: "agy_menubar_metric")
        d.set(manualPort, forKey: "agy_manual_port")
        d.set(manualCsrfToken, forKey: "agy_manual_csrf")
    }

    func applyLoginItem(_ enabled: Bool) {
        guard #available(macOS 13.0, *) else { return }
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            NSLog("❌ Login item error: \(error.localizedDescription)")
        }
    }

    // MARK: - Process Discovery & Fetching

    struct ServerCandidate {
        let pid: Int
        let csrfToken: String
        let ports: [Int]
    }

    func fetchUsage() {
        isLoading = true
        errorMessage = nil

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            // 1. Scan local transcript token statistics
            let stats = self.scanLocalTranscripts()
            let lastSelectedModel = self.readLastSelectedModel()

            // 2. Discover running Antigravity language_server or use manual override
            var candidates: [ServerCandidate] = []
            if let port = Int(self.manualPort.trimmingCharacters(in: .whitespaces)),
               !self.manualCsrfToken.trimmingCharacters(in: .whitespaces).isEmpty {
                candidates.append(ServerCandidate(
                    pid: 0,
                    csrfToken: self.manualCsrfToken.trimmingCharacters(in: .whitespaces),
                    ports: [port]
                ))
            }
            candidates.append(contentsOf: self.discoverLanguageServers())

            guard !candidates.isEmpty else {
                DispatchQueue.main.async {
                    self.localStats = stats
                    self.isLoading = false
                    self.serverConnected = false
                    self.errorMessage = "Antigravity language_server not running. Open Antigravity app first."
                    self.delegate?.updateStatusIcon(percentage: 0, connected: false)
                }
                return
            }

            self.tryCandidates(candidates, stats: stats, lastSelectedModel: lastSelectedModel)
        }
    }

    private func discoverLanguageServers() -> [ServerCandidate] {
        guard let psOutput = runCommand("/bin/ps", args: ["-ax", "-o", "pid=,command="]) else {
            return []
        }

        var results: [ServerCandidate] = []
        let lines = psOutput.components(separatedBy: "\n")

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.contains("language_server"),
                  trimmed.contains("--csrf_token") else { continue }

            let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2, let pid = Int(parts[0]) else { continue }
            let cmd = String(parts[1])

            // Extract --csrf_token <token>
            guard let csrfRange = cmd.range(of: "--csrf_token ") else { continue }
            let afterCsrf = cmd[csrfRange.upperBound...]
            let csrfToken = String(afterCsrf.prefix(while: { !$0.isWhitespace }))
            guard !csrfToken.isEmpty else { continue }

            // Find listening TCP ports for this PID using lsof
            let ports = findListeningPorts(pid: pid)
            if !ports.isEmpty {
                results.append(ServerCandidate(pid: pid, csrfToken: csrfToken, ports: ports))
            }
        }
        return results
    }

    private func findListeningPorts(pid: Int) -> [Int] {
        let lsofPath = FileManager.default.fileExists(atPath: "/usr/sbin/lsof") ? "/usr/sbin/lsof" : "/usr/bin/lsof"
        guard let output = runCommand(lsofPath, args: ["-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-p", "\(pid)"]) else {
            return []
        }
        var ports: [Int] = []
        for line in output.components(separatedBy: "\n") {
            // e.g. TCP 127.0.0.1:51889 (LISTEN)
            if let colonRange = line.range(of: ":", options: .backwards),
               let listenRange = line.range(of: " (LISTEN)") {
                let portStr = line[colonRange.upperBound..<listenRange.lowerBound]
                if let port = Int(portStr), !ports.contains(port) {
                    ports.append(port)
                }
            }
        }
        return ports
    }

    private func tryCandidates(_ candidates: [ServerCandidate], stats: LocalTokenStats, lastSelectedModel: String?) {
        // Build flat list of (pid, csrfToken, port, scheme)
        var endpoints: [(pid: Int, csrf: String, port: Int, scheme: String)] = []
        for c in candidates {
            for port in c.ports {
                endpoints.append((c.pid, c.csrfToken, port, "https"))
                endpoints.append((c.pid, c.csrfToken, port, "http"))
            }
        }

        func attempt(index: Int) {
            if index >= endpoints.count {
                DispatchQueue.main.async {
                    self.localStats = stats
                    self.isLoading = false
                    self.serverConnected = false
                    self.errorMessage = "Could not connect to Antigravity language_server."
                    self.delegate?.updateStatusIcon(percentage: 0, connected: false)
                }
                return
            }

            let ep = endpoints[index]
            let urlStr = "\(ep.scheme)://127.0.0.1:\(ep.port)/exa.language_server_pb.LanguageServerService/GetUserStatus"
            guard let url = URL(string: urlStr) else {
                attempt(index: index + 1)
                return
            }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
            request.setValue(ep.csrf, forHTTPHeaderField: "x-codeium-csrf-token")
            request.httpBody = #"{"metadata":{"ideName":"antigravity","extensionName":"antigravity","locale":"en"}}"#.data(using: .utf8)

            urlSession.dataTask(with: request) { [weak self] data, response, error in
                guard let self = self else { return }
                if let http = response as? HTTPURLResponse, http.statusCode == 200,
                   let data = data,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   json["userStatus"] != nil {
                    DispatchQueue.main.async {
                        self.detectedPid = ep.pid
                        self.detectedPort = ep.port
                        self.serverConnected = true
                        self.isLoading = false
                        self.localStats = stats
                        self.parseUserStatus(json, lastSelectedModel: lastSelectedModel)
                    }
                } else {
                    attempt(index: index + 1)
                }
            }.resume()
        }

        attempt(index: 0)
    }

    private func parseUserStatus(_ root: [String: Any], lastSelectedModel: String?) {
        guard let userStatus = root["userStatus"] as? [String: Any] else { return }

        userName = (userStatus["name"] as? String) ?? ""
        userEmail = (userStatus["email"] as? String) ?? ""

        if let userTier = userStatus["userTier"] as? [String: Any],
           let tName = userTier["name"] as? String {
            tierName = tName
        }

        if let planStatus = userStatus["planStatus"] as? [String: Any] {
            availablePromptCredits = (planStatus["availablePromptCredits"] as? Int) ?? 0
            availableFlowCredits = (planStatus["availableFlowCredits"] as? Int) ?? 0
            if let planInfo = planStatus["planInfo"] as? [String: Any] {
                planName = (planInfo["planName"] as? String) ?? ""
                monthlyPromptCredits = (planInfo["monthlyPromptCredits"] as? Int) ?? 0
                monthlyFlowCredits = (planInfo["monthlyFlowCredits"] as? Int) ?? 0
            }
        }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoNoFrac = ISO8601DateFormatter()
        isoNoFrac.formatOptions = [.withInternetDateTime]

        var defaultModelKey = lastSelectedModel
        if let cascadeData = userStatus["cascadeModelConfigData"] as? [String: Any] {
            if defaultModelKey == nil,
               let defOverride = cascadeData["defaultOverrideModelConfig"] as? [String: Any],
               let mAlias = defOverride["modelOrAlias"] as? [String: Any],
               let mStr = mAlias["model"] as? String {
                defaultModelKey = mStr
            }

            if let configs = cascadeData["clientModelConfigs"] as? [[String: Any]] {
                var parsedModels: [ModelQuotaItem] = []

                for cfg in configs {
                    guard let label = cfg["label"] as? String else { continue }
                    let modelId = (cfg["modelId"] as? String) ?? label
                    let modelPlaceholder = ((cfg["modelOrAlias"] as? [String: Any])?["model"] as? String) ?? ""
                    let quotaInfo = cfg["quotaInfo"] as? [String: Any]

                    let rem: Double
                    if let r = quotaInfo?["remainingFraction"] as? Double {
                        rem = max(0, min(1, r))
                    } else if let rNum = quotaInfo?["remainingFraction"] as? NSNumber {
                        rem = max(0, min(1, rNum.doubleValue))
                    } else {
                        rem = 0.0
                    }

                    let used = max(0, min(1, 1.0 - rem))
                    let resetStr = quotaInfo?["resetTime"] as? String
                    let resetDate = resetStr.flatMap { iso.date(from: $0) ?? isoNoFrac.date(from: $0) }
                    let family = Self.extractFamily(from: label)
                    let isActive = (modelPlaceholder == defaultModelKey) || (modelId == defaultModelKey)
                    let tagTitle = cfg["tagTitle"] as? String
                    let window = PaceWindow.infer(from: resetDate)

                    parsedModels.append(ModelQuotaItem(
                        id: modelId,
                        label: label,
                        family: family,
                        usedFraction: used,
                        remainingFraction: rem,
                        resetTime: resetDate,
                        isActiveModel: isActive,
                        tagTitle: tagTitle,
                        windowSeconds: window
                    ))
                }

                // Sort: Active family first, then Gemini 4, Gemini 3.8, Claude Sonnet, Claude Opus, others
                parsedModels.sort { a, b in
                    Self.sortPriority(for: a.label) < Self.sortPriority(for: b.label)
                }

                allModels = parsedModels
                if let active = parsedModels.first(where: { $0.isActiveModel }) {
                    activeModelLabel = active.label
                } else if let first = parsedModels.first {
                    activeModelLabel = first.label
                }

                // Build grouped models by family (since Low/Medium/High share the same quota pool)
                var familyDict: [String: [ModelQuotaItem]] = [:]
                var familyOrder: [String] = []
                for m in parsedModels {
                    if familyDict[m.family] == nil {
                        familyOrder.append(m.family)
                        familyDict[m.family] = []
                    }
                    familyDict[m.family]?.append(m)
                }

                var grouped: [ModelQuotaItem] = []
                for fam in familyOrder {
                    guard let items = familyDict[fam], let first = items.first else { continue }
                    let hasActive = items.contains(where: { $0.isActiveModel })
                    let maxUsed = items.map { $0.usedFraction }.max() ?? first.usedFraction
                    let minRem = items.map { $0.remainingFraction }.min() ?? first.remainingFraction
                    grouped.append(ModelQuotaItem(
                        id: "family-\(fam)",
                        label: fam,
                        family: fam,
                        usedFraction: maxUsed,
                        remainingFraction: minRem,
                        resetTime: first.resetTime,
                        isActiveModel: hasActive,
                        tagTitle: first.tagTitle,
                        windowSeconds: first.windowSeconds
                    ))
                }
                modelGroups = grouped
            }
        }

        lastUpdated = Date()
        errorMessage = nil
        hasFetchedData = true

        updateStatusBar()
    }

    static func extractFamily(from label: String) -> String {
        for suffix in [" (Low)", " (Medium)", " (High)"] {
            if label.hasSuffix(suffix) {
                return String(label.dropLast(suffix.count))
            }
        }
        return label
    }

    static func sortPriority(for label: String) -> Int {
        if label.contains("Gemini 4") { return 1 }
        if label.contains("Gemini 3") { return 2 }
        if label.contains("Claude Sonnet") { return 3 }
        if label.contains("Claude Opus") { return 4 }
        return 5
    }

    func updateStatusBar() {
        let items = groupModelsByFamily ? modelGroups : allModels
        let pct: Int

        switch menuBarMetric {
        case "highest":
            let maxUsed = items.map { $0.usedFraction }.max() ?? 0
            pct = Int((maxUsed * 100).rounded())
        case "gemini":
            let geminiUsed = items.filter { $0.label.contains("Gemini") }.map { $0.usedFraction }.max() ?? 0
            pct = Int((geminiUsed * 100).rounded())
        case "claude":
            let claudeUsed = items.filter { $0.label.contains("Claude") }.map { $0.usedFraction }.max() ?? 0
            pct = Int((claudeUsed * 100).rounded())
        default: // "active"
            if let active = items.first(where: { $0.isActiveModel }) {
                pct = active.usedPercentageInt
            } else if let first = items.first {
                pct = first.usedPercentageInt
            } else {
                pct = 0
            }
        }

        primaryPercentage = pct
        delegate?.updateStatusIcon(percentage: pct, connected: serverConnected)
        checkNotificationThresholds(percentage: pct)
    }

    func checkNotificationThresholds(percentage: Int) {
        guard usageNotificationsEnabled else { return }

        let thresholds = [25, 50, 75, 90]
        for threshold in thresholds {
            if percentage >= threshold && lastNotifiedThreshold < threshold {
                sendNotification(percentage: percentage, threshold: threshold)
                lastNotifiedThreshold = threshold
                UserDefaults.standard.set(lastNotifiedThreshold, forKey: "agy_last_notified_threshold")
            }
        }

        if percentage < lastNotifiedThreshold {
            let newThreshold = thresholds.filter { $0 <= percentage }.last ?? 0
            lastNotifiedThreshold = newThreshold
            UserDefaults.standard.set(lastNotifiedThreshold, forKey: "agy_last_notified_threshold")
        }
    }

    func sendNotification(percentage: Int, threshold: Int) {
        let notification = NSUserNotification()
        notification.title = "Antigravity Quota Alert"
        notification.informativeText = "Model quota usage reached \(percentage)% (\(activeModelLabel.isEmpty ? "Active Model" : activeModelLabel))"
        notification.soundName = NSUserNotificationDefaultSoundName
        NSUserNotificationCenter.default.deliver(notification)
    }

    func sendTestNotification() {
        let notification = NSUserNotification()
        notification.title = "Antigravity Quota Alert"
        notification.informativeText = "Test notification — Model quota usage at \(primaryPercentage)%"
        notification.soundName = NSUserNotificationDefaultSoundName
        NSUserNotificationCenter.default.deliver(notification)
    }

    // MARK: - Local Filesystem Telemetry

    private func readLastSelectedModel() -> String? {
        let path = NSString(string: "~/.gemini/antigravity/antigravity_state.pbtxt").expandingTildeInPath
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("last_selected_agent_model:") {
                return trimmed.replacingOccurrences(of: "last_selected_agent_model:", with: "")
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private func scanLocalTranscripts() -> LocalTokenStats {
        var stats = LocalTokenStats()
        let fm = FileManager.default
        let roots = [
            "~/.gemini/antigravity/brain",
            "~/.gemini/antigravity-ide/brain",
            "~/.gemini/antigravity-cli/brain"
        ]

        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoNoFrac = ISO8601DateFormatter()
        isoNoFrac.formatOptions = [.withInternetDateTime]

        var seenConvoIds = Set<String>()

        for root in roots {
            let expanded = NSString(string: root).expandingTildeInPath
            guard let convoDirs = try? fm.contentsOfDirectory(atPath: expanded) else { continue }

            for convoId in convoDirs {
                if seenConvoIds.contains(convoId) { continue }
                let transcriptPath = "\(expanded)/\(convoId)/.system_generated/logs/transcript.jsonl"
                guard fm.fileExists(atPath: transcriptPath),
                      let data = try? Data(contentsOf: URL(fileURLWithPath: transcriptPath)),
                      let text = String(data: data, encoding: .utf8) else { continue }

                seenConvoIds.insert(convoId)
                stats.sessionCount += 1

                let attr = try? fm.attributesOfItem(atPath: transcriptPath)
                let modDate = attr?[.modificationDate] as? Date
                let isModifiedToday = modDate.map { $0 >= startOfToday } ?? false

                for line in text.split(separator: "\n") {
                    guard line.contains("\"PLANNER_RESPONSE\""),
                          let lineData = line.data(using: .utf8),
                          let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                          (obj["type"] as? String) == "PLANNER_RESPONSE" else { continue }

                    let inTok = (obj["input_tokens"] as? Int) ?? 0
                    let cacheTok = (obj["cache_read_tokens"] as? Int) ?? 0
                    let outTok = (obj["output_tokens"] as? Int) ?? 0

                    stats.stepCount += 1
                    stats.totalInputTokens += inTok
                    stats.totalCacheTokens += cacheTok
                    stats.totalOutputTokens += outTok

                    if isModifiedToday, let createdStr = obj["created_at"] as? String,
                       let createdDate = isoNoFrac.date(from: createdStr) ?? iso.date(from: createdStr),
                       createdDate >= startOfToday {
                        stats.todayInputTokens += inTok
                        stats.todayCacheTokens += cacheTok
                        stats.todayOutputTokens += outTok
                    }
                }
            }
        }
        return stats
    }

    private func runCommand(_ launchPath: String, args: [String]) -> String? {
        let task = Process()
        task.launchPath = launchPath
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}

// MARK: - SwiftUI Views

private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct UsageView: View {
    @ObservedObject var usageManager: UsageManager
    @State private var showingSettings: Bool = false
    @State private var showingManualOverride: Bool = false
    @State private var measuredHeight: CGFloat = 340
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("agy_appearance_mode") private var appearanceMode: String = "system"
    @AppStorage("agy_reset_time_style") private var resetTimeStyle: String = "countdown"
    @State private var now = Date()
    private let minuteTicker = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    private let maxPopupHeight: CGFloat = 620

    var displayedModels: [ModelQuotaItem] {
        usageManager.groupModelsByFamily ? usageManager.modelGroups : usageManager.allModels
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                content
                    .padding()
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(key: ContentHeightKey.self, value: geo.size.height)
                        }
                    )
            }
            .frame(width: 370, height: min(max(measuredHeight, 140), maxPopupHeight))
            .background(
                colorScheme == .dark
                    ? Color(red: 0.07, green: 0.07, blue: 0.08).opacity(0.3)
                    : Color.white.opacity(0.85)
            )
            .onPreferenceChange(ContentHeightKey.self) { value in
                guard value > 0 else { return }
                measuredHeight = value
            }
            .onReceive(minuteTicker) { now = $0 }
            .onAppear {
                now = Date()
            }
            .onChange(of: showingSettings) { isOpen in
                if isOpen {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            proxy.scrollTo("settings-anchor", anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("Antigravity Usage")
                            .font(.headline)
                        if !usageManager.tierName.isEmpty {
                            Text(usageManager.tierName)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.accentColor))
                        }
                    }
                    if !usageManager.userEmail.isEmpty {
                        Text("\(usageManager.userName.isEmpty ? "" : "\(usageManager.userName) · ")\(usageManager.userEmail)")
                            .font(.caption2)
                            .foregroundColor(Color.secondaryText)
                    }
                }
                Spacer()
                HStack(spacing: 5) {
                    Circle()
                        .fill(usageManager.serverConnected ? Color.green : Color.orange)
                        .frame(width: 7, height: 7)
                    Text(usageManager.serverConnected ? "Live" : "Offline")
                        .font(.caption2)
                        .foregroundColor(Color.secondaryText)
                }
            }

            if let error = usageManager.errorMessage {
                VStack(alignment: .leading, spacing: 6) {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.orange)
                    Button("Retry Connection") {
                        usageManager.fetchUsage()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .padding(8)
                .background(Color.orange.opacity(0.1))
                .cornerRadius(6)
            }

            // Model Quota Bars
            if usageManager.hasFetchedData && !displayedModels.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Model Quotas")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(Color.secondaryText)
                        Spacer()
                        Button(action: {
                            usageManager.groupModelsByFamily.toggle()
                            usageManager.saveSettings()
                            usageManager.updateStatusBar()
                        }) {
                            Text(usageManager.groupModelsByFamily ? "Grouped" : "All Tiers")
                                .font(.caption2)
                                .foregroundColor(.accentColor)
                        }
                        .buttonStyle(.borderless)
                    }

                    ForEach(displayedModels) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 5) {
                                Text(item.label)
                                    .font(.subheadline)
                                    .fontWeight(item.isActiveModel ? .semibold : .regular)
                                if item.isActiveModel {
                                    Text("ACTIVE")
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundColor(.accentColor)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(
                                            RoundedRectangle(cornerRadius: 3)
                                                .stroke(Color.accentColor, lineWidth: 1)
                                        )
                                }
                                Spacer()
                                if let resetTime = item.resetTime {
                                    let isWeekly = item.windowSeconds > 6 * 3600
                                    Text(resetText(resetTime, includeDate: isWeekly))
                                        .help(resetHelp(resetTime, includeDate: isWeekly))
                                        .font(.caption)
                                        .foregroundColor(Color.secondaryText)
                                }
                            }

                            UsageBar(
                                value: item.usedFraction,
                                color: colorForPercentage(item.usedFraction),
                                pace: paceMarker(resetsAt: item.resetTime, window: item.windowSeconds)
                            )

                            HStack {
                                Text("\(item.usedPercentageInt)% used")
                                    .font(.caption)
                                    .foregroundColor(Color.secondaryText)
                                Spacer()
                                Text("\(max(0, 100 - item.usedPercentageInt))% remaining")
                                    .font(.caption2)
                                    .foregroundColor(Color.secondaryText)
                            }
                        }
                    }
                }
            }

            // Plan Credits (Prompt / Flow credits)
            if usageManager.hasFetchedData && (usageManager.availablePromptCredits > 0 || usageManager.availableFlowCredits > 0) {
                Divider()
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Prompt Credits")
                            .font(.caption2)
                            .foregroundColor(Color.secondaryText)
                        Text("\(formatNumber(usageManager.availablePromptCredits)) available")
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Flow Credits")
                            .font(.caption2)
                            .foregroundColor(Color.secondaryText)
                        Text("\(formatNumber(usageManager.availableFlowCredits)) available")
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                }
            }

            Divider()

            // Local Token Telemetry (~/.gemini/antigravity/brain)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Local Token Telemetry")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(Color.secondaryText)
                    Spacer()
                    Text("\(usageManager.localStats.sessionCount) sessions · \(formatNumber(usageManager.localStats.stepCount)) steps")
                        .font(.caption2)
                        .foregroundColor(Color.secondaryText)
                }

                HStack(spacing: 8) {
                    tokenCard(
                        title: "Today",
                        inTokens: usageManager.localStats.todayInputTokens,
                        outTokens: usageManager.localStats.todayOutputTokens,
                        cacheTokens: usageManager.localStats.todayCacheTokens
                    )
                    tokenCard(
                        title: "All-Time",
                        inTokens: usageManager.localStats.totalInputTokens,
                        outTokens: usageManager.localStats.totalOutputTokens,
                        cacheTokens: usageManager.localStats.totalCacheTokens
                    )
                }
            }

            Divider()

            // Footer: Last updated + Refresh
            HStack {
                Text("Updated \(formatTime(usageManager.lastUpdated))\(usageManager.detectedPort > 0 ? " · port \(usageManager.detectedPort)" : "")")
                    .font(.caption2)
                    .foregroundColor(Color.secondaryText)
                Spacer()
                Button("Refresh") {
                    usageManager.fetchUsage()
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }

            // Settings & Connection Override buttons
            HStack(spacing: 14) {
                Button(showingSettings ? "Hide Settings" : "Settings") {
                    showingSettings.toggle()
                }
                .buttonStyle(.borderless)
                .font(.caption)

                Button(showingManualOverride ? "Hide Server Config" : "Server Config") {
                    showingManualOverride.toggle()
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundColor(Color.secondaryText)

                Spacer()

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundColor(.red.opacity(0.85))
            }

            if showingManualOverride {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Auto-Detection Status")
                        .font(.caption)
                        .fontWeight(.semibold)
                    Text(usageManager.serverConnected
                         ? "Connected to PID \(usageManager.detectedPid) on 127.0.0.1:\(usageManager.detectedPort)"
                         : "Auto-discovering local Antigravity language_server process via ps/lsof.")
                        .font(.caption2)
                        .foregroundColor(Color.secondaryText)

                    Text("Optional Manual Override (leave blank for auto):")
                        .font(.caption2)
                        .foregroundColor(Color.secondaryText)

                    HStack(spacing: 6) {
                        TextField("Port", text: $usageManager.manualPort)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                            .font(.caption)
                        TextField("CSRF Token", text: $usageManager.manualCsrfToken)
                            .textFieldStyle(.roundedBorder)
                            .font(.caption)
                    }

                    HStack(spacing: 8) {
                        Button("Save & Reconnect") {
                            usageManager.saveSettings()
                            usageManager.fetchUsage()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)

                        Button("Use Auto-Detect") {
                            usageManager.manualPort = ""
                            usageManager.manualCsrfToken = ""
                            usageManager.saveSettings()
                            usageManager.fetchUsage()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding(8)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(6)
            }

            if showingSettings {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Menu Bar Percentage")
                            .font(.caption)
                        ChoicePills(
                            selection: Binding(
                                get: { usageManager.menuBarMetric },
                                set: { val in
                                    usageManager.menuBarMetric = val
                                    usageManager.saveSettings()
                                    usageManager.updateStatusBar()
                                }
                            ),
                            options: [
                                ("Active", "active"),
                                ("Highest", "highest"),
                                ("Gemini", "gemini"),
                                ("Claude", "claude")
                            ]
                        )
                        Text("Choose which model quota percentage appears in the menu bar")
                            .font(.caption2)
                            .foregroundColor(Color.secondaryText)
                    }

                    Divider()

                    Toggle(isOn: Binding(
                        get: { usageManager.openAtLogin },
                        set: { newValue in
                            usageManager.openAtLogin = newValue
                            usageManager.applyLoginItem(newValue)
                            usageManager.saveSettings()
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Open at Login")
                                .font(.caption)
                            Text("Launch AntigravityUsageBar automatically when you log in")
                                .font(.caption2)
                                .foregroundColor(Color.secondaryText)
                        }
                    }
                    .toggleStyle(.checkbox)

                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(isOn: Binding(
                            get: { usageManager.usageNotificationsEnabled },
                            set: { newValue in
                                usageManager.usageNotificationsEnabled = newValue
                                usageManager.saveSettings()
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Enable Usage Notifications")
                                    .font(.caption)
                                Text("Get alerts at 25%, 50%, 75%, and 90% quota usage")
                                    .font(.caption2)
                                    .foregroundColor(Color.secondaryText)
                            }
                        }
                        .toggleStyle(.checkbox)

                        Button("Test Notification") {
                            usageManager.sendTestNotification()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Reset times")
                            .font(.caption)
                        ChoicePills(
                            selection: $resetTimeStyle,
                            options: [("Time left", "countdown"), ("Date", "date")]
                        )
                    }

                    Divider()

                    Toggle(isOn: Binding(
                        get: { usageManager.paceMarkerEnabled },
                        set: { newValue in
                            usageManager.paceMarkerEnabled = newValue
                            usageManager.saveSettings()
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Show Pace Marker")
                                .font(.caption)
                            Text("Mark where usage should sit based on elapsed window time")
                                .font(.caption2)
                                .foregroundColor(Color.secondaryText)
                        }
                    }
                    .toggleStyle(.checkbox)

                    Divider()

                    Toggle(isOn: Binding(
                        get: { usageManager.shortcutEnabled },
                        set: { newValue in
                            usageManager.shortcutEnabled = newValue
                            usageManager.saveSettings()
                            if let appDelegate = NSApplication.shared.delegate as? AppDelegate {
                                appDelegate.setShortcutEnabled(newValue)
                            }
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Keyboard Shortcut (⌘⇧U)")
                                .font(.caption)
                            Text("Toggle popup from anywhere")
                                .font(.caption2)
                                .foregroundColor(Color.secondaryText)
                        }
                    }
                    .toggleStyle(.switch)

                    Divider()

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Appearance")
                            .font(.caption)
                        ChoicePills(
                            selection: $appearanceMode,
                            options: [("System", "system"), ("Dark", "dark"), ("Light", "light")]
                        )
                        .onChange(of: appearanceMode) { _ in
                            (NSApplication.shared.delegate as? AppDelegate)?.applyAppearancePreference()
                        }
                    }
                }
                .padding(8)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(6)

                Color.clear
                    .frame(height: 1)
                    .id("settings-anchor")
            }
        }
    }

    @ViewBuilder
    func tokenCard(title: String, inTokens: Int, outTokens: Int, cacheTokens: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundColor(Color.secondaryText)
            Text("\(formatCompact(inTokens + outTokens)) tok")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
            Text("In \(formatCompact(inTokens)) · Out \(formatCompact(outTokens))")
                .font(.system(size: 9))
                .foregroundColor(Color.secondaryText)
            Text("Cache \(formatCompact(cacheTokens))")
                .font(.system(size: 9))
                .foregroundColor(Color.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(7)
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(6)
    }

    func formatCompact(_ n: Int) -> String {
        if n >= 1_000_000 {
            return String(format: "%.1fM", Double(n) / 1_000_000.0)
        } else if n >= 1_000 {
            return String(format: "%.1fK", Double(n) / 1_000.0)
        }
        return "\(n)"
    }

    func formatNumber(_ number: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: number)) ?? "\(number)"
    }

    func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    static func countdown(to date: Date, from now: Date) -> String {
        let mins = Int((date.timeIntervalSince(now) / 60).rounded(.up))
        let d = mins / 1440, h = (mins % 1440) / 60, m = mins % 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    private func timeLeft(_ date: Date) -> String {
        date <= now ? "now" : "in \(Self.countdown(to: date, from: now))"
    }

    func resetText(_ date: Date, includeDate: Bool = true) -> String {
        resetTimeStyle == "date" ? "Resets \(formatResetTime(date, includeDate: includeDate))" : "Resets \(timeLeft(date))"
    }

    func resetHelp(_ date: Date, includeDate: Bool = true) -> String {
        resetTimeStyle == "date" ? "Resets \(timeLeft(date))" : "Resets \(formatResetTime(date, includeDate: includeDate))"
    }

    func formatResetTime(_ date: Date, includeDate: Bool = false) -> String {
        let formatter = DateFormatter()
        if includeDate {
            formatter.dateFormat = "d MMM 'at' h:mm a"
            return "on \(formatter.string(from: date))"
        } else {
            formatter.timeStyle = .short
            formatter.dateStyle = .none
            return "at \(formatter.string(from: date))"
        }
    }

    func paceMarker(resetsAt: Date?, window: TimeInterval) -> PaceMarker? {
        guard usageManager.paceMarkerEnabled,
              let pace = Pace(resetsAt: resetsAt, window: window) else { return nil }
        let percent = Int((pace.expected * 100).rounded())
        return PaceMarker(
            expected: pace.expected,
            tooltip: "On pace: \(percent)% by now · \(formatElapsed(pace.elapsed)) in"
        )
    }

    func formatElapsed(_ interval: TimeInterval) -> String {
        let totalMinutes = max(0, Int(interval / 60))
        let days = totalMinutes / 1440
        let hours = (totalMinutes % 1440) / 60
        let minutes = totalMinutes % 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    func colorForPercentage(_ percentage: Double) -> Color {
        if percentage < 0.7 {
            return .green
        } else if percentage < 0.9 {
            return .orange
        } else {
            return .red
        }
    }
}
