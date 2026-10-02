import AppKit
import SwiftUI
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem!
    private var popover: NSPopover!
    private var settingsWindow: NSWindow?
    private var previewWindow: NSWindow?
    private var subscription: AnyCancellable?
    private let state = AppState(demo: CommandLine.arguments.contains("--demo"))

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installMainMenu()
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "gauge.with.dots.needle.50percent", accessibilityDescription: "UsageBar")
            button.imagePosition = .imageLeading
            button.target = self; button.action = #selector(togglePopover)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 400, height: 580)
        popover.contentViewController = NSHostingController(rootView: DashboardView(state: state, openSettings: { [weak self] in self?.showSettings() }))
        subscription = state.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.updateStatus()
                self?.updateDashboardSize()
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(woke), name: NSWorkspace.didWakeNotification, object: nil)
        updateStatus(); updateDashboardSize(); state.start()
        if CommandLine.arguments.contains("--show-settings") { showSettings() }
        if CommandLine.arguments.contains("--show-window") || CommandLine.arguments.contains("--export-preview") {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 580), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "UsageBar · 演示"
            window.contentView = NSHostingView(rootView: DashboardView(state: state, openSettings: { [weak self] in self?.showSettings() }))
            previewWindow = window
            updateDashboardSize()
            window.center(); window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        if state.demo, let index = CommandLine.arguments.firstIndex(of: "--export-preview"), CommandLine.arguments.count > index + 1 {
            let directory = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
            Task { @MainActor in
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    self.previewWindow?.appearance = NSAppearance(named: .aqua)
                    try await Task.sleep(nanoseconds: 700_000_000)
                    try self.savePreview(window: self.previewWindow, name: "dashboard-light", directory: directory)
                    self.previewWindow?.appearance = NSAppearance(named: .darkAqua)
                    try await Task.sleep(nanoseconds: 400_000_000)
                    try self.savePreview(window: self.previewWindow, name: "dashboard-dark", directory: directory)
                    self.state.balance = nil; self.state.hasKey = false
                    try await Task.sleep(nanoseconds: 400_000_000)
                    self.updateDashboardSize()
                    try self.savePreview(window: self.previewWindow, name: "dashboard-unconnected", directory: directory)
                    self.showSettings()
                    self.settingsWindow?.appearance = NSAppearance(named: .aqua)
                    try await Task.sleep(nanoseconds: 400_000_000)
                    try self.savePreview(window: self.settingsWindow, name: "settings", directory: directory)
                    print("UsageBar previews exported to \(directory.path)")
                } catch { print("Preview failed: \(error.localizedDescription)") }
                NSApp.terminate(nil)
            }
        }
        if CommandLine.arguments.contains("--smoke-test") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                print("UsageBar smoke: status item created; demo=\(self.state.demo); codex=\(self.state.codex != nil); deepseek=\(self.state.balance != nil)")
                NSApp.terminate(nil)
            }
        }
    }
    private func updateStatus() {
        item.button?.title = state.menuTitle
        item.button?.toolTip = state.menuTooltip
    }
    private func installMainMenu() {
        // This AppKit entry point does not get SwiftUI App's default Edit commands.
        // Nil targets route shortcuts to the active text field via the responder chain.
        let mainMenu = NSMenu()
        let applicationMenu = NSMenu(title: "UsageBar")
        applicationMenu.addItem(withTitle: "设置…", action: #selector(showSettings), keyEquivalent: ",").target = self
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(withTitle: "退出 UsageBar", action: #selector(quit), keyEquivalent: "q").target = self
        let applicationItem = mainMenu.addItem(withTitle: "UsageBar", action: nil, keyEquivalent: "")
        applicationItem.submenu = applicationMenu

        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = mainMenu.addItem(withTitle: "编辑", action: nil, keyEquivalent: "")
        editItem.submenu = editMenu
        NSApp.mainMenu = mainMenu
    }
    private func updateDashboardSize() {
        // Let the complete content determine the height instead of clipping it to 580 pt.
        if let view = popover?.contentViewController?.view {
            view.layoutSubtreeIfNeeded()
            let height = ceil(view.fittingSize.height)
            if height.isFinite && height > 0 { popover.contentSize = NSSize(width: 400, height: height) }
        }
        if let window = previewWindow, let view = window.contentView {
            view.layoutSubtreeIfNeeded()
            let height = ceil(view.fittingSize.height)
            if height.isFinite && height > 0 { window.setContentSize(NSSize(width: 400, height: height)) }
        }
    }
    private func savePreview(window: NSWindow?, name: String, directory: URL) throws {
        guard let view = window?.contentView else { return }
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return }
        try data.write(to: directory.appendingPathComponent(name + ".png"))
    }
    @objc private func woke() { state.wake() }
    @objc private func togglePopover() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(withTitle: "刷新全部", action: #selector(refresh), keyEquivalent: "r").target = self
            menu.addItem(withTitle: "设置…", action: #selector(showSettings), keyEquivalent: ",").target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "退出 UsageBar", action: #selector(quit), keyEquivalent: "q").target = self
            item.menu = menu; item.button?.performClick(nil); item.menu = nil
        } else if popover.isShown { popover.performClose(nil) }
        else if let button = item.button {
            updateDashboardSize()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            NSApp.activate(ignoringOtherApps: true)
        }
    }
    @objc private func refresh() { state.refreshAll() }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc func showSettings() {
        popover.performClose(nil)
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 660), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = state.demo ? "UsageBar 设置 · 演示" : "UsageBar 设置"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(state: state))
            settingsWindow = window
        }
        settingsWindow?.center(); settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
@MainActor
enum UsageBarMain {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
