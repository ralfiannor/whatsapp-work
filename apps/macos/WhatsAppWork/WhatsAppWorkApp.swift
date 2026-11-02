// App entry + root scenes.
import SwiftUI
import UserNotifications
import CoreServices

@main
struct WhatsAppWorkApp: App {
    @StateObject private var state = AppState()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    private let responderActions = ResponderActionDispatcher()

    init() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Hosted unit tests launch this app; XCTest marks the host's environment.
    static func isUnitTestHost(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment["XCTestConfigurationFilePath"] != nil
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(state)
                .frame(minWidth: 900, minHeight: 560)
                // wa.me "Continue to Chat" → whatsapp://send?phone=&text=
                // (we register the scheme; see Info.plist CFBundleURLTypes).
                .onOpenURL { url in
                    Task { @MainActor in await state.handleWhatsAppLink(url) }
                }
                // Without this, every inbound URL makes the WindowGroup open
                // a second window; the open window takes the link instead.
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    Task { await state.updater.checkNow(userInitiated: true) }
                }
            }
            CommandGroup(replacing: .pasteboard) {
                Button("Cut") { responderActions.perform(.cut) }
                    .keyboardShortcut("x", modifiers: .command)
                Button("Copy") { responderActions.perform(.copy) }
                    .keyboardShortcut("c", modifiers: .command)
                Button("Paste") {
                    if !state.handlePaste() { responderActions.perform(.paste) }
                }
                    .keyboardShortcut("v", modifiers: .command)
                Button("Paste and Match Style") { responderActions.perform(.pasteAndMatchStyle) }
                    .keyboardShortcut("v", modifiers: [.command, .option, .shift])
            }
            CommandGroup(after: .newItem) {
                Button("Refresh Chats") { Task { await state.refreshChats() } }
                    .keyboardShortcut("r", modifiers: .command)
                Button("Search") { state.searchOpen = true }
                    .keyboardShortcut("k", modifiers: .command)
                Button("New Note") {
                    state.openNotes()
                    state.notes.create()
                }
                    .keyboardShortcut("n", modifiers: [.command, .option])
            }
            CommandMenu("Go") {
                Button("All Chats") { Task { await state.applyFilter("all") } }
                    .keyboardShortcut("1", modifiers: .command)
                Button("Unread") { Task { await state.applyFilter("unread") } }
                    .keyboardShortcut("2", modifiers: .command)
                Button("Mentions") { Task { await state.applyFilter("mentions") } }
                    .keyboardShortcut("3", modifiers: .command)
                Button("Inbox") { state.showInbox() }
                    .keyboardShortcut("4", modifiers: .command)
                Button("Notes") { state.openNotes() }
                    .keyboardShortcut("5", modifiers: .command)
                Button("Next Unread") { Task { await state.jumpNextUnread() } }
                    .keyboardShortcut("j", modifiers: .command)
            }
            CommandMenu("Account") {
                Button(state.focusMode ? "Disable Focus Mode" : "Enable Focus Mode") {
                    state.toggleFocusMode()
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                Divider()
                Button("Set as wa.me Link Handler") {
                    // Claim the whatsapp:// scheme so "Continue to Chat"
                    // (wa.me) links open here — needed when the official
                    // Desktop client is also installed.
                    let bid = (Bundle.main.bundleIdentifier ?? "dev.whatsappwork.WhatsAppWork") as CFString
                    LSSetDefaultHandlerForURLScheme("whatsapp" as CFString, bid)
                    LSSetDefaultHandlerForURLScheme("whatsappwork" as CFString, bid)
                    state.toast = "wa.me links now open in WhatsApp Work"
                }
                Divider()
                Button("Log Out (wipes local data)…") { state.confirmingLogout = true }
            }
        }
        Settings {
            SettingsView()
        }
    }
}

/// Ensures the sidecar dies with the app — no orphaned lock holders.
/// Also the notification-center delegate: clicking a notification opens its
/// conversation (previously the click only activated the app).
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    static var state: AppState?

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // SwiftUI restores the window AFTER this callback — a synchronous
        // clamp would see no windows. Retry past restoration (fast and slow
        // paths; first pass wins, second is a no-op when the frame is fine).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            Self.clampWindowsToScreens(forceMainScreen: true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            Self.clampWindowsToScreens(forceMainScreen: true)
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        Self.clampWindowsToScreens(forceMainScreen: false)
    }

    /// A restored window frame can land on a monitor that is no longer
    /// attached (or outside every screen entirely) — the app then "runs with
    /// no window". At LAUNCH, also pull windows parked on a secondary screen
    /// back to the main one: the user repeatedly launched to "no window"
    /// because the frame restored onto the other monitor. While merely
    /// activating, only fully-invisible windows are moved (during use, a
    /// secondary screen is a valid user choice).
    static func clampWindowsToScreens(forceMainScreen: Bool) {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }
        // screens.first is the PRIMARY screen (menu bar). NSScreen.main is
        // the screen WITH FOCUS — when the restored window sits on the
        // secondary display, that IS "main", and the clamp would no-op.
        let main = screens[0].visibleFrame
        for window in NSApp.windows where window.isVisible && window.isMovable {
            let frame = window.frame
            let visible = screens
                .map(\.visibleFrame)
                .reduce(0) { $0 + $1.intersection(frame).width }
            let barelyVisible = visible < 100 // < ~100 pt of the window on any screen
            let offMain = forceMainScreen && !main.intersects(frame)
            guard barelyVisible || offMain else { continue }
            var next = frame
            next.origin.x = main.minX + 60
            next.origin.y = main.maxY - frame.height - 60
            if next.width > main.width || next.height > main.height {
                next.size = NSSize(width: min(frame.width, main.width - 40),
                                   height: min(frame.height, main.height - 40))
            }
            window.setFrame(next, display: true)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Note edits are saved on a short debounce; don't lose the last one.
        AppDelegate.state?.notes.flush()
        // Synchronous: an async stop loses the race with process exit and
        // orphans a core holding the DB lock.
        AppDelegate.state?.sidecar.stopBlocking()
        // A verified, staged update replaces this bundle only now, with the
        // core stopped (and reopens it after "Restart to Update").
        AppDelegate.state?.updater.installPendingUpdate()
        return .terminateNow
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let messageID = response.notification.request.identifier
        Task { @MainActor in
            await AppDelegate.state?.openChat(fromNotification: messageID)
        }
        completionHandler()
    }
}

struct RootView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        // v1 is a dark-first IRC terminal: force dark APP-WIDE. The old
        // per-transcript override left a light sidebar glued to a black
        // transcript under the system light theme.
        Group {
            switch state.screen {
            case .login: LoginView()
            case .main: MainView()
            }
        }
        .environment(\.colorScheme, .dark)
        .background(Color(white: 0.07))
        .overlay(alignment: .top) { ConnectionBanner(sidecar: state.sidecar) }
        .overlay(alignment: .bottom) { ToastView() }
        .sheet(isPresented: $state.searchOpen) { SearchOverlay() }
        .alert("Log out and wipe local data?", isPresented: $state.confirmingLogout) {
            Button("Log Out", role: .destructive) { Task { await state.logout() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This Mac is unlinked from WhatsApp and its local message history and media cache are deleted. Your phone keeps everything; linking again re-syncs history.")
        }
        .onAppear {
            AppDelegate.state = state
            // Booting a test host would spawn a real core on the developer's
            // data dir, and orphan reclaim would kill the core of any running
            // copy of the app to take the lock.
            guard !WhatsAppWorkApp.isUnitTestHost() else { return }
            state.boot()
        }
    }
}

/// Bottom-center transient toast. Fixed-height slot (overlay, zero layout
/// impact); errors were previously written to state and shown nowhere.
struct ToastView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Group {
            if let toast = state.toast {
                Text(toast)
                    .font(.system(size: 11.5, design: .monospaced))
                    .lineLimit(2)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Capsule().fill(.regularMaterial)
                        .overlay(Capsule().strokeBorder(.quaternary)))
                    .foregroundStyle(.primary)
                    .padding(.bottom, 14)
                    .transition(.opacity)
                    .accessibilityLabel("Notification: \(toast)")
            }
        }
        // A toast appearing elsewhere on screen is invisible to VoiceOver
        // unless announced; errors must not be sight-only.
        .onChange(of: state.toast) { _, toast in
            guard let toast else { return }
            AccessibilityNotification.Announcement(toast).post()
        }
    }
}

/// Top-center status capsule. Core (sidecar) trouble outranks connection
/// state: a core that failed to start used to leave only an endless
/// "Connecting…" spinner with no reason and no way out but quitting.
struct ConnectionBanner: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var sidecar: SidecarManager

    var body: some View {
        Group {
            switch sidecar.phase {
            case .failed(let reason):
                failedBanner(reason)
            case .restarting:
                banner("Restarting the WhatsApp core…", color: .orange)
            default:
                switch state.connectionState {
                case "connecting", "offline":
                    banner("Reconnecting…", color: .orange)
                case "linking":
                    banner("Waiting for QR scan…", color: .blue)
                default:
                    EmptyView()
                }
            }
        }
    }

    private func banner(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.callout)
            .padding(.vertical, 4).padding(.horizontal, 12)
            .background(Capsule().fill(.regularMaterial))
            .foregroundStyle(color)
            .overlay(Capsule().strokeBorder(color.opacity(0.5)))
            .padding(.top, 6)
    }

    private func failedBanner(_ reason: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .accessibilityHidden(true)
            Text("WhatsApp core stopped: \(reason)")
                .font(.callout)
                .lineLimit(2)
            Button("Restart") { sidecar.restartNow() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(.vertical, 5).padding(.horizontal, 12)
        .background(Capsule().fill(.regularMaterial))
        .overlay(Capsule().strokeBorder(Color.red.opacity(0.5)))
        .padding(.top, 6)
        .accessibilityElement(children: .combine)
    }
}

/// Sidebar footer for a verified, staged update — or one this copy can't
/// install itself. Every other updater state stays out of sight: checks
/// and downloads run in the background.
struct UpdateBar: View {
    @ObservedObject var updater: UpdateManager

    var body: some View {
        switch updater.status {
        case .ready(let version):
            bar("WhatsApp Work \(version) is ready", button: "Restart",
                help: "Quit, install the update and reopen") {
                updater.restartToUpdate()
            }
        case .manualOnly(let version, let page):
            bar("WhatsApp Work \(version) is available", button: "Download",
                help: "This copy can't replace itself — open the release page") {
                NSWorkspace.shared.open(page)
            }
        default:
            EmptyView()
        }
    }

    private func bar(_ title: String, button: String, help: String,
                     action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            Text(title)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Button(button, action: action)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help(help)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}
