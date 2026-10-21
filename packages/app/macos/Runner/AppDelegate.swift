import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  private var statusItem: NSStatusItem?
  var windowChannel: FlutterMethodChannel?

  private var appName: String {
    Bundle.main.localizedInfoDictionary?["CFBundleDisplayName"] as? String ?? "Hongguo"
  }
  private func text(_ en: String, _ hans: String, _ hant: String) -> String {
    let language = Bundle.main.preferredLocalizations.first ?? "en"
    return language.hasPrefix("zh") ? (language.contains("Hant") ? hant : hans) : en
  }

  override func applicationDidFinishLaunching(_ notification: Notification) {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    if let button = item.button {
      let image = NSImage(systemSymbolName: "play.rectangle.fill", accessibilityDescription: appName)
      image?.isTemplate = true
      button.image = image
      button.toolTip = appName
      button.target = self
      button.action = #selector(statusClicked(_:))
      button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }
    statusItem = item
    if let settings = NSApp.mainMenu?.items.first?.submenu?.items.first(where: { $0.keyEquivalent == "," }) {
      settings.target = self; settings.action = #selector(openSettings(_:))
    }
    super.applicationDidFinishLaunching(notification)
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    showWindow(nil)
    return false
  }

  @objc func showWindow(_ sender: Any?) {
    guard let window = mainFlutterWindow else { return }
    NSApp.unhide(nil)
    window.deminiaturize(nil)
    window.makeKeyAndOrderFront(nil)
    if let view = window.contentViewController?.view { window.makeFirstResponder(view) }
    NSApp.activate(ignoringOtherApps: true)
  }

  @objc private func hideWindow(_ sender: Any?) { mainFlutterWindow?.orderOut(sender) }
  @objc private func openSettings(_ sender: Any?) {
    showWindow(sender)
    windowChannel?.invokeMethod("settings", arguments: nil)
  }
  @objc private func about(_ sender: Any?) {
    showWindow(sender)
    NSApp.orderFrontStandardAboutPanel(options: [.applicationName: appName])
  }
  @objc private func quit(_ sender: Any?) { NSApp.terminate(sender) }

  var settingsAvailable = false
  func statusMenu() -> NSMenu {
    let menu = NSMenu()
    func add(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
      let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
      item.target = self; menu.addItem(item); return item
    }
    _ = add(text("Show Window", "显示主窗口", "顯示主視窗"), #selector(showWindow(_:)))
    _ = add(text("Hide Window", "隐藏窗口", "隱藏視窗"), #selector(hideWindow(_:)))
    menu.addItem(.separator())
    let settings = add(text("Settings…", "设置…", "設定…"), #selector(openSettings(_:)), key: ",")
    settings.isEnabled = settingsAvailable
    _ = add(text("About ", "关于 ", "關於 ") + appName, #selector(about(_:)))
    menu.addItem(.separator())
    _ = add(text("Quit ", "退出 ", "結束 ") + appName, #selector(quit(_:)), key: "q")
    menu.autoenablesItems = false
    return menu
  }
  @objc private func statusClicked(_ sender: Any?) {
    if let event = NSApp.currentEvent,
       event.type == .rightMouseUp || event.modifierFlags.contains(.control),
       let button = statusItem?.button {
      statusMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button)
    } else { showWindow(sender) }
  }
  var hasStatusItem: Bool { statusItem?.button != nil }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}
