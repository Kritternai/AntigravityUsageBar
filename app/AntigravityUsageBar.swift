import SwiftUI
import AppKit
import Carbon
import ServiceManagement

/// Segmented control in the site's style: a soft track with a raised chip for
/// the selection. Native segmented pickers only tint while their window is key,
/// which the popover never is.
struct ChoicePills: View {
    @Binding var selection: String
    let options: [(label: String, tag: String)]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.tag) { option in
                let selected = selection == option.tag
                Button(action: {
                    withAnimation(.easeOut(duration: 0.15)) { selection = option.tag }
                }) {
                    Text(option.label)
                        .font(.system(size: 11.5, weight: selected ? .semibold : .regular))
                        .foregroundColor(selected ? .agyText : .agyText2)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(selected ? Color.agySurface : Color.clear)
                                .shadow(color: .black.opacity(selected ? 0.08 : 0), radius: 1, y: 1)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.agyTrack))
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
                Capsule().fill(Color.agyTrack)
                Capsule()
                    .fill(color)
                    .frame(width: max(0, min(1, value)) * geo.size.width)
                    .animation(.easeOut(duration: 0.4), value: value)
                if let pace = pace {
                    Rectangle()
                        .fill(Color.agyText.opacity(0.55))
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
        .frame(height: 5)
        .onHover { isHovering = $0 }
    }
}

struct PaceTooltip: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(.agyText)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.agySurface).shadow(color: .black.opacity(0.12), radius: 2, y: 1))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.agyLine, lineWidth: 1))
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
        statusItem.autosaveName = "AntigravityUsageBar"

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
            color = NSColor(red: 0.13, green: 0.77, blue: 0.37, alpha: 1.0)
        } else if percentage < 90 {
            color = NSColor(red: 1.0, green: 0.75, blue: 0.0, alpha: 1.0)
        } else {
            color = NSColor(red: 1.0, green: 0.23, blue: 0.19, alpha: 1.0)
        }

        button.image = createAntigravityIcon(color: color)
        button.imagePosition = .imageLeft
        button.title = connected ? "\(percentage)%" : "--%"
        button.appearsDisabled = false
        button.isEnabled = true
    }

    /// Four-point star with subtle core, matching the Antigravity mark.
    func createAntigravityIcon(color: NSColor) -> NSImage {
        let size = NSSize(width: 14, height: 14)
        let image = NSImage(size: size)

        image.lockFocus()

        let p = NSBezierPath()
        p.move(to: NSPoint(x: 7, y: 1))
        p.curve(to: NSPoint(x: 13, y: 7), controlPoint1: NSPoint(x: 8, y: 5), controlPoint2: NSPoint(x: 9, y: 6))
        p.curve(to: NSPoint(x: 7, y: 13), controlPoint1: NSPoint(x: 9, y: 8), controlPoint2: NSPoint(x: 8, y: 9))
        p.curve(to: NSPoint(x: 1, y: 7), controlPoint1: NSPoint(x: 6, y: 9), controlPoint2: NSPoint(x: 5, y: 8))
        p.curve(to: NSPoint(x: 7, y: 1), controlPoint1: NSPoint(x: 5, y: 6), controlPoint2: NSPoint(x: 6, y: 5))
        p.close()

        color.setFill()
        p.fill()

        let centerDot = NSBezierPath(ovalIn: NSRect(x: 6, y: 6, width: 2, height: 2))
        NSColor.white.withAlphaComponent(0.9).setFill()
        centerDot.fill()

        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}

/// Status-colour values shared by the menu bar icon (AppKit) and the popover.
enum AgyPalette {
    static let green = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(srgbRed: 0.133, green: 0.773, blue: 0.369, alpha: 1)
        : NSColor(srgbRed: 0.086, green: 0.639, blue: 0.290, alpha: 1) }
    static let amber = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(srgbRed: 0.961, green: 0.620, blue: 0.043, alpha: 1)
        : NSColor(srgbRed: 0.851, green: 0.467, blue: 0.024, alpha: 1) }
    static let red = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(srgbRed: 0.937, green: 0.267, blue: 0.267, alpha: 1)
        : NSColor(srgbRed: 0.863, green: 0.149, blue: 0.149, alpha: 1) }
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
        if CommandLine.arguments.contains("--snapshot") {
            SnapshotGenerator.run()
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

// MARK: - Snapshot Generator for Documentation & Assets

struct SnapshotGenerator {
    static func run() {
        _ = NSApplication.shared

        let um = UsageManager(statusItem: nil, delegate: nil)
        um.userName = "Developer"
        um.userEmail = "dev@antigravity.internal"
        um.tierName = "Antigravity Pro"
        um.planName = "Internal Early Access"
        um.serverConnected = true
        um.detectedPort = 58214
        um.detectedPid = 38419
        um.primaryPercentage = 34
        um.activeModelLabel = "Gemini 2.5 Pro"

        let m1 = ModelQuotaItem(
            id: "gemini-2.5-pro",
            label: "Gemini 2.5 Pro",
            family: "Gemini 2.5 Pro",
            usedFraction: 0.34,
            remainingFraction: 0.66,
            resetTime: Date().addingTimeInterval(3.5 * 3600),
            isActiveModel: true,
            tagTitle: "Active",
            windowSeconds: 18000
        )
        let m2 = ModelQuotaItem(
            id: "claude-3.7-sonnet",
            label: "Claude 3.7 Sonnet (Thinking)",
            family: "Claude 3.7 Sonnet",
            usedFraction: 0.68,
            remainingFraction: 0.32,
            resetTime: Date().addingTimeInterval(1.2 * 3600),
            isActiveModel: false,
            tagTitle: "Thinking",
            windowSeconds: 18000
        )
        let m3 = ModelQuotaItem(
            id: "gemini-2.5-flash",
            label: "Gemini 2.5 Flash",
            family: "Gemini 2.5 Flash",
            usedFraction: 0.12,
            remainingFraction: 0.88,
            resetTime: Date().addingTimeInterval(4.5 * 3600),
            isActiveModel: false,
            tagTitle: nil,
            windowSeconds: 18000
        )

        um.modelGroups = [m1, m2, m3]
        um.allModels = [m1, m2, m3]
        um.localStats = LocalTokenStats(
            sessionCount: 28,
            stepCount: 142,
            todayInputTokens: 384200,
            todayCacheTokens: 295100,
            todayOutputTokens: 68400,
            totalInputTokens: 1120000,
            totalCacheTokens: 940000,
            totalOutputTokens: 362000
        )

        let fm = FileManager.default
        let currentDir = fm.currentDirectoryPath
        // Detect repo root (parent of app/ or current if at root)
        let rootDir: URL
        if currentDir.hasSuffix("/app") {
            rootDir = URL(fileURLWithPath: currentDir).deletingLastPathComponent()
        } else {
            rootDir = URL(fileURLWithPath: currentDir)
        }

        let assetsDir = rootDir.appendingPathComponent("assets")
        let docsAssetsDir = rootDir.appendingPathComponent("docs/assets")
        try? fm.createDirectory(at: assetsDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: docsAssetsDir, withIntermediateDirectories: true)

        // 1. Standalone cards
        saveView(
            SnapshotCard(isDark: false) { UsageView(usageManager: um, initialPage: .main, defaultHeight: 480) },
            to: assetsDir.appendingPathComponent("screenshot-dashboard.png")
        )
        saveView(
            SnapshotCard(isDark: true) { UsageView(usageManager: um, initialPage: .main, defaultHeight: 480) },
            to: assetsDir.appendingPathComponent("screenshot-dark.png")
        )
        saveView(
            SnapshotCard(isDark: false) { UsageView(usageManager: um, initialPage: .settings, defaultHeight: 520) },
            to: assetsDir.appendingPathComponent("screenshot-settings.png")
        )

        // 2. Hero showcase (macOS menu bar context)
        saveView(
            SnapshotShowcase(isDark: false, content: UsageView(usageManager: um, initialPage: .main, defaultHeight: 480)),
            to: assetsDir.appendingPathComponent("preview-hero.png")
        )
        saveView(
            SnapshotShowcase(isDark: true, content: UsageView(usageManager: um, initialPage: .main, defaultHeight: 480)),
            to: assetsDir.appendingPathComponent("preview-hero-dark.png")
        )

        // Sync to docs/assets
        for name in ["screenshot-dashboard.png", "screenshot-dark.png", "screenshot-settings.png", "preview-hero.png", "preview-hero-dark.png"] {
            let src = assetsDir.appendingPathComponent(name)
            let dst = docsAssetsDir.appendingPathComponent(name)
            try? fm.removeItem(at: dst)
            try? fm.copyItem(at: src, to: dst)
        }

        print("✅ Snapshots generated in \(assetsDir.path) and \(docsAssetsDir.path)")
        exit(0)
    }

    static func saveView<V: View>(_ view: V, to url: URL) {
        let hostingView = NSHostingView(rootView: view)
        let size = hostingView.fittingSize
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()

        guard let rep = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else { return }
        hostingView.cacheDisplay(in: hostingView.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: url)
            print("Wrote \(url.lastPathComponent) (\(data.count) bytes)")
        }
    }
}

struct SnapshotCard<Content: View>: View {
    let isDark: Bool
    let content: Content

    init(isDark: Bool, @ViewBuilder content: () -> Content) {
        self.isDark = isDark
        self.content = content()
    }

    var body: some View {
        content
            .preferredColorScheme(isDark ? .dark : .light)
            .background(Color.agySurface)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.agyLine, lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(isDark ? 0.45 : 0.12), radius: 18, x: 0, y: 8)
            .padding(20)
            .background(Color.clear)
    }
}

struct SnapshotShowcase: View {
    let isDark: Bool
    let content: UsageView

    var body: some View {
        VStack(spacing: 0) {
            // Simulated macOS Menu Bar
            HStack(spacing: 12) {
                HStack(spacing: 14) {
                    Image(systemName: "applelogo")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Antigravity")
                        .font(.system(size: 13, weight: .semibold))
                    Text("File")
                        .font(.system(size: 13))
                    Text("Edit")
                        .font(.system(size: 13))
                    Text("View")
                        .font(.system(size: 13))
                    Text("Window")
                        .font(.system(size: 13))
                    Text("Help")
                        .font(.system(size: 13))
                }
                .foregroundColor(isDark ? .white.opacity(0.85) : .black.opacity(0.85))

                Spacer()

                HStack(spacing: 12) {
                    HStack(spacing: 5) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Color.agyGreen)
                        Text("34%")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundColor(isDark ? .white : .black)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(isDark ? Color.white.opacity(0.12) : Color.black.opacity(0.08))
                    )

                    Image(systemName: "wifi")
                        .font(.system(size: 12))
                    Image(systemName: "battery.100")
                        .font(.system(size: 13))
                    Text("Mon 11:24")
                        .font(.system(size: 12))
                }
                .foregroundColor(isDark ? .white.opacity(0.85) : .black.opacity(0.85))
            }
            .padding(.horizontal, 18)
            .frame(height: 30)
            .background(isDark ? Color(white: 0.12).opacity(0.96) : Color(white: 0.96).opacity(0.96))
            .overlay(
                Rectangle()
                    .fill(isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.08))
                    .frame(height: 1),
                alignment: .bottom
            )

            ZStack(alignment: .topTrailing) {
                LinearGradient(
                    colors: isDark
                        ? [Color(white: 0.08), Color(white: 0.04)]
                        : [Color(white: 0.94), Color(white: 0.98)],
                    startPoint: .top,
                    endPoint: .bottom
                )

                content
                    .background(Color.agySurface)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.agyLine, lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(isDark ? 0.55 : 0.16), radius: 24, x: 0, y: 12)
                    .padding(.top, 10)
                    .padding(.trailing, 90)
                    .padding(.bottom, 24)
            }
        }
        .frame(width: 640)
        .preferredColorScheme(isDark ? .dark : .light)
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
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.updateStatusBar()
            }
            return
        }

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

// Palette mirrored from the website (docs/index.html): neutral grays, one blue
// accent, and green / amber / red reserved for quota state.
extension Color {
    static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    static let agySurface = adaptive(light: .white, dark: NSColor(white: 0.08, alpha: 1))
    static let agySoft    = adaptive(light: NSColor(white: 0.965, alpha: 1), dark: NSColor(white: 0.11, alpha: 1))
    static let agyTrack   = adaptive(light: NSColor(white: 0.925, alpha: 1), dark: NSColor(white: 0.16, alpha: 1))
    static let agyLine    = adaptive(light: NSColor(white: 0.90, alpha: 1), dark: NSColor(white: 0.15, alpha: 1))
    static let agyText    = adaptive(light: NSColor(white: 0.04, alpha: 1), dark: NSColor(white: 0.98, alpha: 1))
    static let agyText2   = adaptive(light: NSColor(white: 0.32, alpha: 1), dark: NSColor(white: 0.64, alpha: 1))
    static let agyText3   = adaptive(light: NSColor(white: 0.58, alpha: 1), dark: NSColor(white: 0.45, alpha: 1))
    static let agyAccent  = adaptive(light: NSColor(srgbRed: 0.145, green: 0.388, blue: 0.922, alpha: 1),
                                     dark: NSColor(srgbRed: 0.376, green: 0.647, blue: 0.980, alpha: 1))
    static let agyGreen   = Color(nsColor: AgyPalette.green)
    static let agyAmber   = Color(nsColor: AgyPalette.amber)
    static let agyRed     = Color(nsColor: AgyPalette.red)
}

private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Small borderless icon button with a soft hover background.
struct IconButton: View {
    let systemName: String
    var label: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(hover ? .agyText : .agyText2)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7).fill(hover ? Color.agySoft : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .onHover { hover = $0 }
    }
}

/// Capsule button: dark filled (primary) or outlined (secondary), like the site.
struct PillButton: View {
    let title: String
    var primary: Bool = true
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(primary ? .agySurface : .agyText)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(primary ? Color.agyText.opacity(hover ? 0.85 : 1) : Color.clear)
                )
                .overlay(Capsule().stroke(primary ? Color.clear : (hover ? Color.agyText3 : Color.agyLine), lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// Plain text link-style button.
struct TextButton: View {
    let title: String
    var color: Color = .agyText3
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5))
                .foregroundColor(hover ? .agyText : color)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// Monochrome switch. Native switches render gray in the never-key popover.
struct MiniSwitch: View {
    @Binding var isOn: Bool

    var body: some View {
        Button(action: { withAnimation(.easeOut(duration: 0.15)) { isOn.toggle() } }) {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? Color.agyText : Color.agyTrack)
                    .frame(width: 28, height: 16)
                Circle()
                    .fill(isOn ? Color.agySurface : Color.white)
                    .shadow(color: .black.opacity(0.15), radius: 1, y: 0.5)
                    .frame(width: 12, height: 12)
                    .padding(2)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

struct UsageView: View {
    @ObservedObject var usageManager: UsageManager

    enum Page { case main, settings }

    @State private var page: Page = .main
    @State private var showAdvanced = false
    @State private var testSent = false
    @State private var measuredHeight: CGFloat = 360
    @AppStorage("agy_appearance_mode") private var appearanceMode: String = "system"
    @AppStorage("agy_reset_time_style") private var resetTimeStyle: String = "countdown"
    @State private var now = Date()
    private let minuteTicker = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    private let popupWidth: CGFloat = 340
    private let maxPopupHeight: CGFloat = 600

    init(usageManager: UsageManager, initialPage: Page = .main, defaultHeight: CGFloat = 360) {
        self.usageManager = usageManager
        self._page = State(initialValue: initialPage)
        self._measuredHeight = State(initialValue: defaultHeight)
    }

    var displayedModels: [ModelQuotaItem] {
        usageManager.groupModelsByFamily ? usageManager.modelGroups : usageManager.allModels
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            Group {
                switch page {
                case .main: mainPage
                case .settings: settingsPage
                }
            }
            .padding(20)
            .frame(width: popupWidth, alignment: .topLeading)
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: ContentHeightKey.self, value: geo.size.height)
                }
            )
        }
        .frame(width: popupWidth, height: min(max(measuredHeight, 160), maxPopupHeight))
        .background(Color.agySurface)
        .onPreferenceChange(ContentHeightKey.self) { value in
            guard value > 0 else { return }
            measuredHeight = value
        }
        .onReceive(minuteTicker) { now = $0 }
        .onAppear { now = Date() }
    }

    // MARK: Main page

    var mainPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, 20)

            if !usageManager.hasFetchedData {
                emptyState
            } else {
                if !usageManager.serverConnected, let error = usageManager.errorMessage {
                    notice(error)
                        .padding(.bottom, 16)
                }

                VStack(alignment: .leading, spacing: 16) {
                    ForEach(displayedModels) { item in
                        quotaRow(item)
                    }
                }

                hairline.padding(.vertical, 18)

                tokenStats

                if usageManager.availablePromptCredits > 0 || usageManager.availableFlowCredits > 0 {
                    Text("Prompt credits \(formatNumber(usageManager.availablePromptCredits)) · Flow \(formatNumber(usageManager.availableFlowCredits))")
                        .font(.system(size: 11))
                        .foregroundColor(.agyText3)
                        .padding(.top, 14)
                }
            }

            hairline
                .padding(.top, 18)
                .padding(.bottom, 12)

            HStack {
                Text(usageManager.hasFetchedData ? "Updated \(formatTime(usageManager.lastUpdated))" : "Not connected")
                    .font(.system(size: 11))
                    .foregroundColor(.agyText3)
                Spacer()
                TextButton(title: "Quit") { NSApplication.shared.terminate(nil) }
            }
        }
    }

    var header: some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text("Antigravity Usage")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.agyText)
                    if usageManager.hasFetchedData && !usageManager.tierName.isEmpty {
                        Text(usageManager.tierName)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundColor(.agyText2)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .overlay(Capsule().stroke(Color.agyLine, lineWidth: 1))
                    }
                }
                if !usageManager.userEmail.isEmpty {
                    Text(usageManager.userEmail)
                        .font(.system(size: 11))
                        .foregroundColor(.agyText3)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            IconButton(systemName: "arrow.clockwise", label: "Refresh") {
                usageManager.fetchUsage()
            }
            .opacity(usageManager.isLoading ? 0.4 : 1)
            IconButton(systemName: "gearshape", label: "Settings") {
                page = .settings
            }
        }
    }

    func quotaRow(_ item: ModelQuotaItem) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(item.label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.agyText)
                    .lineLimit(1)
                if item.isActiveModel {
                    Text("ACTIVE")
                        .font(.system(size: 9.5, weight: .semibold))
                        .kerning(0.4)
                        .foregroundColor(.agyAccent)
                }
                Spacer(minLength: 8)
                if let reset = item.resetTime {
                    let isWeekly = item.windowSeconds > 6 * 3600
                    Text(resetText(reset, includeDate: isWeekly))
                        .font(.system(size: 11.5))
                        .foregroundColor(.agyText3)
                        .monospacedDigit()
                }
            }

            UsageBar(
                value: item.usedFraction,
                color: colorForPercentage(item.usedFraction),
                pace: paceMarker(resetsAt: item.resetTime, window: item.windowSeconds)
            )

            Text("\(item.usedPercentageInt)% used")
                .font(.system(size: 11.5))
                .foregroundColor(.agyText3)
                .monospacedDigit()
        }
    }

    var tokenStats: some View {
        let s = usageManager.localStats
        return HStack(alignment: .top, spacing: 12) {
            stat(label: "Tokens today",
                 value: formatCompact(s.todayTotal),
                 detail: "In \(formatCompact(s.todayInputTokens)) · Out \(formatCompact(s.todayOutputTokens))")
            stat(label: "All time",
                 value: formatCompact(s.lifetimeTotal),
                 detail: "\(s.sessionCount) sessions")
        }
    }

    func stat(label: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.agyText3)
            Text(value)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.agyText)
                .monospacedDigit()
            Text(detail)
                .font(.system(size: 10.5))
                .foregroundColor(.agyText3)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var emptyState: some View {
        VStack(spacing: 10) {
            if usageManager.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .padding(.bottom, 4)
                Text("Connecting to Antigravity…")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.agyText)
            } else {
                Image(systemName: "moon.zzz")
                    .font(.system(size: 22, weight: .light))
                    .foregroundColor(.agyText3)
                    .padding(.bottom, 2)
                Text("Antigravity isn't running")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.agyText)
                Text("Open Antigravity and your quotas\nwill appear here.")
                    .font(.system(size: 11.5))
                    .foregroundColor(.agyText3)
                    .multilineTextAlignment(.center)
                PillButton(title: "Try again") { usageManager.fetchUsage() }
                    .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
    }

    func notice(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 12))
                .foregroundColor(.agyAmber)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundColor(.agyText2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.agySoft))
    }

    var hairline: some View {
        Rectangle()
            .fill(Color.agyLine)
            .frame(height: 1)
    }

    // MARK: Settings page

    var settingsPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                IconButton(systemName: "chevron.left", label: "Back") { page = .main }
                Text("Settings")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.agyText)
                Spacer()
            }
            .padding(.leading, -6)
            .padding(.bottom, 18)

            sectionLabel("Menu bar")
            card {
                VStack(alignment: .leading, spacing: 8) {
                    rowTitle("Show percentage for")
                    ChoicePills(
                        selection: Binding(
                            get: { usageManager.menuBarMetric },
                            set: { value in
                                usageManager.menuBarMetric = value
                                usageManager.saveSettings()
                                usageManager.updateStatusBar()
                            }
                        ),
                        options: [("Active", "active"), ("Highest", "highest"), ("Gemini", "gemini"), ("Claude", "claude")]
                    )
                }
            }

            sectionLabel("Display")
            card {
                toggleRow("Group model tiers", "Combine Low, Medium and High",
                          isOn: Binding(
                            get: { usageManager.groupModelsByFamily },
                            set: { value in
                                usageManager.groupModelsByFamily = value
                                usageManager.saveSettings()
                                usageManager.updateStatusBar()
                            }))
                cardDivider
                toggleRow("Pace marker", "Show where usage should be by now",
                          isOn: Binding(
                            get: { usageManager.paceMarkerEnabled },
                            set: { value in
                                usageManager.paceMarkerEnabled = value
                                usageManager.saveSettings()
                            }))
                cardDivider
                VStack(alignment: .leading, spacing: 8) {
                    rowTitle("Reset times")
                    ChoicePills(selection: $resetTimeStyle,
                                options: [("Time left", "countdown"), ("Date", "date")])
                }
                cardDivider
                VStack(alignment: .leading, spacing: 8) {
                    rowTitle("Appearance")
                    ChoicePills(selection: $appearanceMode,
                                options: [("System", "system"), ("Light", "light"), ("Dark", "dark")])
                        .onChange(of: appearanceMode) { _ in
                            (NSApplication.shared.delegate as? AppDelegate)?.applyAppearancePreference()
                        }
                }
            }

            sectionLabel("General")
            card {
                toggleRow("Open at login", nil,
                          isOn: Binding(
                            get: { usageManager.openAtLogin },
                            set: { value in
                                usageManager.openAtLogin = value
                                usageManager.applyLoginItem(value)
                                usageManager.saveSettings()
                            }))
                cardDivider
                toggleRow("Notifications", "At 25, 50, 75 and 90%",
                          isOn: Binding(
                            get: { usageManager.usageNotificationsEnabled },
                            set: { value in
                                usageManager.usageNotificationsEnabled = value
                                usageManager.saveSettings()
                            }))
                cardDivider
                toggleRow("Keyboard shortcut", "⌘⇧U toggles this popover",
                          isOn: Binding(
                            get: { usageManager.shortcutEnabled },
                            set: { value in
                                usageManager.shortcutEnabled = value
                                usageManager.saveSettings()
                                (NSApplication.shared.delegate as? AppDelegate)?.setShortcutEnabled(value)
                            }))
            }

            Button(action: { withAnimation(.easeOut(duration: 0.15)) { showAdvanced.toggle() } }) {
                HStack(spacing: 4) {
                    Text("Advanced")
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(showAdvanced ? 90 : 0))
                    Spacer()
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.agyText3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 18)
            .padding(.bottom, 8)

            if showAdvanced {
                card {
                    VStack(alignment: .leading, spacing: 4) {
                        rowTitle("Server")
                        Text(usageManager.serverConnected
                             ? "Connected · PID \(usageManager.detectedPid) · port \(usageManager.detectedPort)"
                             : "Auto-detecting the local language_server")
                            .font(.system(size: 11))
                            .foregroundColor(.agyText3)
                    }
                    cardDivider
                    VStack(alignment: .leading, spacing: 8) {
                        rowTitle("Manual override")
                        HStack(spacing: 6) {
                            TextField("Port", text: $usageManager.manualPort)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 70)
                            TextField("CSRF token", text: $usageManager.manualCsrfToken)
                                .textFieldStyle(.roundedBorder)
                        }
                        .font(.system(size: 11.5))
                        HStack(spacing: 8) {
                            PillButton(title: "Save") {
                                usageManager.saveSettings()
                                usageManager.fetchUsage()
                            }
                            PillButton(title: "Auto-detect", primary: false) {
                                usageManager.manualPort = ""
                                usageManager.manualCsrfToken = ""
                                usageManager.saveSettings()
                                usageManager.fetchUsage()
                            }
                        }
                    }
                }
            }

            HStack {
                TextButton(title: testSent ? "Notification sent" : "Send test notification") {
                    usageManager.sendTestNotification()
                    testSent = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { testSent = false }
                }
                Spacer()
                Text("v\(appVersion)")
                    .font(.system(size: 11))
                    .foregroundColor(.agyText3)
            }
            .padding(.top, 16)
        }
    }

    func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(.agyText3)
            .padding(.bottom, 8)
            .padding(.top, 2)
    }

    func rowTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12.5))
            .foregroundColor(.agyText)
    }

    @ViewBuilder
    func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.agySoft))
        .padding(.bottom, 14)
    }

    var cardDivider: some View {
        Rectangle()
            .fill(Color.agyLine)
            .frame(height: 1)
    }

    func toggleRow(_ title: String, _ subtitle: String?, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                rowTitle(title)
                if let subtitle = subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(.agyText3)
                }
            }
            Spacer(minLength: 8)
            MiniSwitch(isOn: isOn)
                .accessibilityLabel(title)
        }
    }

    var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    // MARK: Formatting

    func formatCompact(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.2fM", Double(n) / 1_000_000.0) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000.0) }
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

    func resetText(_ date: Date, includeDate: Bool) -> String {
        if resetTimeStyle == "date" {
            let f = DateFormatter()
            f.dateFormat = includeDate ? "d MMM, h:mm a" : "h:mm a"
            return "Resets \(f.string(from: date))"
        }
        return date <= now ? "Resets now" : "Resets in \(Self.countdown(to: date, from: now))"
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

    func colorForPercentage(_ fraction: Double) -> Color {
        if fraction < 0.7 { return .agyGreen }
        if fraction < 0.9 { return .agyAmber }
        return .agyRed
    }
}
