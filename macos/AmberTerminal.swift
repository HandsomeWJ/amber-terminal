// Amber Terminal for macOS: the app in this repo in a window of its own, with its own Dock icon.
// It reuses the server already running from this folder, or starts it with scripts/launch.js, and
// shows it in a WKWebView. Closing the window keeps the app in the Dock, so desktop alerts keep
// coming; quitting leaves the server running, so webhook alerts still fire, and Amber Terminal >
// Stop Server and Quit stops both. Build it with macos/build.sh.
import AppKit
import UserNotifications
import WebKit

/// The app folder and the node to run it with; macos/build.sh writes both into Info.plist.
let installDir = Bundle.main.object(forInfoDictionaryKey: "QTInstallDir") as? String
  ?? NSString(string: "~/Documents/amber-terminal").expandingTildeInPath
let nodePath = Bundle.main.object(forInfoDictionaryKey: "QTNodePath") as? String
let helpURL = URL(string: "https://github.com/HandsomeWJ/amber-terminal#readme")!

struct LaunchError: Error {
  let message: String
  var retry = true  // false when ⌘R can't help until something outside the app changes
}

/// The window loads the address the server listens on and the app checked. ("localhost" can resolve
/// to ::1 first, which another program could be holding.)
func appURL(port: Int) -> URL { URL(string: "http://127.0.0.1:\(port)")! }

/// Asks each port the server may take (3787 to 3807, as scripts/launch.js does) for the copy running
/// from this folder, so a running server is reused without starting node. A busy server can miss the
/// quick pass, so a slower pass runs before deciding that none is running.
func findRunningServer() async -> URL? {
  let wanted = URL(fileURLWithPath: installDir).resolvingSymlinksInPath().path.lowercased()
  for timeout in [0.7, 3.0] {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = timeout
    let session = URLSession(configuration: config)
    defer { session.invalidateAndCancel() }
    for port in 3787...3807 {
      guard let reply = try? await session.data(from: appURL(port: port).appendingPathComponent("api/health")),
        let health = try? JSONSerialization.jsonObject(with: reply.0) as? [String: Any],
        health["app"] as? String == "amber-terminal",
        let root = health["root"] as? String,
        URL(fileURLWithPath: root).resolvingSymlinksInPath().path.lowercased() == wanted
      else { continue }
      return appURL(port: port)
    }
  }
  return nil
}

/// The part of the app's environment node needs. Nothing else is passed on, so a variable set for
/// the app (HOST, AMBER_HOST, PORT, NODE_OPTIONS, QT_DATA_DIR) can't change how or where the server runs.
func nodeEnvironment(node: String) -> [String: String] {
  let keep: Set = ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY", "http_proxy", "https_proxy", "no_proxy"]
  var env = ProcessInfo.processInfo.environment.filter { keep.contains($0.key) || $0.key.hasPrefix("LC_") }
  // An app opened from the Dock gets a bare PATH; the server finds node next to the one that started it.
  env["PATH"] = URL(fileURLWithPath: node).deletingLastPathComponent().path + ":/usr/bin:/bin:/usr/sbin:/sbin"
  env["QT_NO_OPEN"] = "1"
  return env
}

/// macOS asks before an app reads Documents; if the answer was no, node only sees "not permitted".
let privacyBlocked = LaunchError(
  message: "macOS didn't let Amber Terminal open \(installDir). Allow it in System Settings > Privacy & Security > Files & Folders > Amber Terminal, then press ⌘R.",
  retry: false)

func blockedByPrivacy(_ text: String) -> LaunchError? {
  text.contains("EPERM") || text.localizedCaseInsensitiveContains("operation not permitted") ? privacyBlocked : nil
}

/// Runs scripts/launch.js, which starts the server from this folder and prints its address.
func launchServer() -> Result<URL, LaunchError> {
  let rebuild = "then run macos/build.sh in the app folder again so this app knows where things are."
  // A moved folder and a "no" to macOS's Documents prompt both look missing; the error code tells them apart.
  do {
    _ = try FileManager.default.attributesOfItem(atPath: installDir + "/scripts/launch.js")
  } catch let error as NSError where error.code == NSFileReadNoSuchFileError {
    return .failure(LaunchError(message: "The app folder isn't at \(installDir) any more. Find where it went, \(rebuild)", retry: false))
  } catch {
    return .failure(privacyBlocked)
  }
  let candidates = [nodePath, "/opt/homebrew/bin/node", "/usr/local/bin/node"]
  guard let node = candidates.compactMap({ $0 }).first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
    return .failure(LaunchError(message: "Node.js isn't at \(nodePath ?? "/opt/homebrew/bin/node") any more. Install it (nodejs.org, or brew install node), \(rebuild)", retry: false))
  }
  let process = Process()
  process.executableURL = URL(fileURLWithPath: node)
  process.arguments = ["scripts/launch.js", "--no-open"]
  process.currentDirectoryURL = URL(fileURLWithPath: installDir)
  process.environment = nodeEnvironment(node: node)
  let pipe = Pipe()
  process.standardOutput = pipe
  process.standardError = pipe
  do { try process.run() } catch {
    return .failure(blockedByPrivacy("\(error)") ?? LaunchError(message: "Couldn't run \(node): \(error.localizedDescription)"))
  }
  // launch.js exits once the server answers; the server itself writes to data/server.log, not here.
  let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
  process.waitUntilExit()
  if process.terminationStatus == 0,
    let range = output.range(of: #"http://localhost:\d+"#, options: .regularExpression),
    let port = Int(output[range].split(separator: ":").last ?? "")
  {
    return .success(appURL(port: port))
  }
  if let blocked = blockedByPrivacy(output) { return .failure(blocked) }
  return .failure(LaunchError(message: output.isEmpty ? "scripts/launch.js stopped with code \(process.terminationStatus)." : output))
}

/// The app's one page: Back and Forward come off the right-click menu, since they'd only lead to the
/// start-up page.
final class AppWebView: WKWebView {
  override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
    menu.items.removeAll { ["WKMenuItemIdentifierGoBack", "WKMenuItemIdentifierGoForward"].contains($0.identifier?.rawValue ?? "") }
    super.willOpenMenu(menu, with: event)
  }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate,
  WKScriptMessageHandlerWithReply, UNUserNotificationCenterDelegate
{
  var window: NSWindow!
  var webView: WKWebView!
  var origin: URL?
  var serverWasRunning = false
  private var starting = false
  private var quitWhenStarted = false
  private var crashes = 0
  private var downloads: [ObjectIdentifier: URL] = [:]

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.mainMenu = makeMenu()
    UNUserNotificationCenter.current().delegate = self
    let config = WKWebViewConfiguration()
    config.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "qtNotify")
    webView = AppWebView(frame: .zero, configuration: config)
    webView.navigationDelegate = self
    webView.uiDelegate = self
    if #available(macOS 13.3, *) { webView.isInspectable = true }  // Safari's Develop menu can inspect it
    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    window.title = "Amber Terminal"
    window.isReleasedWhenClosed = false  // closing only hides it; the Dock icon brings it back
    window.minSize = NSSize(width: 900, height: 560)
    window.contentView = webView
    window.center()
    window.setFrameAutosaveName("Amber Terminal")
    window.makeKeyAndOrderFront(nil)
    activate()
    openApp()
  }

  // The page keeps running with its window closed, so its desktop alerts keep coming.
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
    window.makeKeyAndOrderFront(nil)
    return true
  }

  /// Finds or starts the server, then shows the app. Reload (⌘R) runs it again, which restarts a stopped server.
  @objc func openApp() {
    guard !starting else { return }
    starting = true
    if origin == nil { show("Starting Amber Terminal…") }
    Task {
      let running = await findRunningServer()
      serverWasRunning = running != nil
      let result: Result<URL, LaunchError>
      if let running {
        result = .success(running)
      } else {
        result = await Task.detached(priority: .userInitiated) { launchServer() }.value
      }
      starting = false
      if quitWhenStarted {
        if case .success(let url) = result { origin = url }
        return stopServerAndQuit()
      }
      switch result {
      case .success(let url):
        origin = url
        await addPageScripts()
        webView.load(URLRequest(url: url))
      case .failure(let error):
        origin = nil
        show("Amber Terminal couldn't start.\n\n\(error.message)\n\nApp folder: \(installDir)\(error.retry ? "\nPress ⌘R to try again." : "")", dim: false)
      }
    }
  }

  /// A plain page for the start-up and error text, in the terminal's amber on black.
  private func show(_ text: String, dim: Bool = true) {
    let escaped = text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
    webView.loadHTMLString(
      """
      <!doctype html><meta charset="utf-8"><style>
      :root { color-scheme: dark; font: 14px ui-monospace, Menlo, monospace; }
      body { margin: 0; height: 100vh; display: grid; place-items: center; background: #000; color: #ffa028; }
      pre { font: inherit; white-space: pre-wrap; max-width: 620px; padding: 0 24px; opacity: \(dim ? 0.6 : 1); }
      </style><pre>\(escaped)</pre>
      """, baseURL: nil)
  }

  /// The page's alerts use the web Notification API, which this window doesn't have; this stands in
  /// for it with native notifications, starting from the permission macOS has on record.
  private func addPageScripts() async {
    let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    let permission = status == .authorized || status == .provisional ? "granted" : status == .denied ? "denied" : "default"
    let controller = webView.configuration.userContentController
    controller.removeAllUserScripts()
    controller.addUserScript(
      WKUserScript(
        source: """
          (() => {
            const native = window.webkit.messageHandlers.qtNotify;
            class Notification {
              static permission = "\(permission)";
              static requestPermission() {
                return native.postMessage({ action: "request" }).then((p) => (Notification.permission = p));
              }
              constructor(title, options = {}) {
                native.postMessage({ action: "show", title: String(title), body: String(options.body ?? "") }).catch(() => {});
              }
            }
            window.Notification = Notification;
          })();
          """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
    #if QT_SELFTEST
      controller.addUserScript(selfTestErrorCapture)
    #endif
  }

  func userContentController(
    _ controller: WKUserContentController, didReceive message: WKScriptMessage,
    replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
  ) {
    let from = message.frameInfo.securityOrigin
    guard message.frameInfo.isMainFrame, from.host == origin?.host, from.port == origin?.port,
      let body = message.body as? [String: Any]
    else { return replyHandler(nil, "Not allowed") }
    let center = UNUserNotificationCenter.current()
    switch body["action"] as? String {
    case "request":
      center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
        Task { @MainActor in replyHandler(granted ? "granted" : "denied", nil) }
      }
    case "show":
      let content = UNMutableNotificationContent()
      content.title = body["title"] as? String ?? "Amber Terminal"
      content.body = body["body"] as? String ?? ""
      content.sound = .default
      center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
      replyHandler(nil, nil)
    default:
      replyHandler(nil, "Unknown action")
    }
  }

  // Alerts show even while this window is in front, as they do in a browser.
  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .sound])
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    Task { @MainActor in
      activate()
      self.window.makeKeyAndOrderFront(nil)
    }
    completionHandler()
  }

  // MARK: Navigation: the app's own pages stay here, web links open in the browser.

  private func isApp(_ url: URL) -> Bool {
    url.scheme == "http" && url.host == origin?.host && url.port == origin?.port
  }

  private func openOutside(_ url: URL) {
    guard ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") else { return }
    #if QT_SELFTEST
      selfTestRecordLink(url)
    #else
      NSWorkspace.shared.open(url)
    #endif
  }

  func webView(
    _ webView: WKWebView, decidePolicyFor action: WKNavigationAction, preferences: WKWebpagePreferences,
    decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
  ) {
    if action.shouldPerformDownload { return decisionHandler(.download, preferences) }
    guard let url = action.request.url else { return decisionHandler(.cancel, preferences) }
    if url.scheme == "about" || isApp(url) { return decisionHandler(.allow, preferences) }
    openOutside(url)
    decisionHandler(.cancel, preferences)
  }

  func webView(
    _ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
    decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
  ) {
    decisionHandler(response.canShowMIMEType ? .allow : .download)
  }

  // Links with target="_blank" (news, Help) ask for a new window: open them in the browser instead.
  func webView(
    _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction,
    windowFeatures: WKWindowFeatures
  ) -> WKWebView? {
    if let url = action.request.url { openOutside(url) }
    return nil
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    guard let url = webView.url, isApp(url) else { return }
    crashes = 0
    #if QT_SELFTEST
      selfTestStart()
    #endif
  }

  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    let e = error as NSError
    // Cancelled loads and links turned into downloads land here too; only a real failure is shown.
    if e.domain == NSURLErrorDomain && e.code == NSURLErrorCancelled || e.domain == "WebKitErrorDomain" && e.code == 102 { return }
    show("The app didn't load: \(e.localizedDescription)\n\nPress ⌘R to try again.", dim: false)
  }

  // One crash reloads the page; a second before it loads again stops, rather than reloading forever.
  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    crashes += 1
    if crashes < 2 { return openApp() }
    show("The page stopped unexpectedly twice in a row.\n\nPress ⌘R to try again.", dim: false)
  }

  // MARK: Downloads: each screen's Export (one CSV file) goes to ~/Downloads.

  func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
    download.delegate = self
  }

  func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
    download.delegate = self
  }

  var downloadsFolder: URL {
    #if QT_SELFTEST
      if let dir = ProcessInfo.processInfo.environment["QT_SELFTEST_DOWNLOADS"] { return URL(fileURLWithPath: dir) }
    #endif
    return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
  }

  func download(
    _ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
    completionHandler: @escaping @MainActor @Sendable (URL?) -> Void
  ) {
    let name = (suggestedFilename as NSString).lastPathComponent
    let first = downloadsFolder.appendingPathComponent(name.isEmpty ? "download" : name)
    let base = first.deletingPathExtension().lastPathComponent, ext = first.pathExtension
    var url = first
    var n = 1
    // An existing file is kept: "WEI-2026-11-03.csv", then "WEI-2026-11-03 2.csv", as Finder names copies.
    while FileManager.default.fileExists(atPath: url.path) {
      n += 1
      url = downloadsFolder.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
    }
    downloads[ObjectIdentifier(download)] = url
    completionHandler(url)
  }

  func downloadDidFinish(_ download: WKDownload) {
    guard let url = downloads.removeValue(forKey: ObjectIdentifier(download)) else { return }
    // Bounces the Downloads stack in the Dock, as browsers do.
    DistributedNotificationCenter.default().post(name: .init("com.apple.DownloadFileFinished"), object: url.path)
  }

  func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
    downloads.removeValue(forKey: ObjectIdentifier(download))
    let alert = NSAlert()
    alert.messageText = "The download didn't finish."
    alert.informativeText = error.localizedDescription
    present(alert) { _ in }
  }

  // MARK: The page's alert, confirm and prompt, and its file picker, as sheets on the window.

  func webView(
    _ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
    completionHandler: @escaping @MainActor @Sendable () -> Void
  ) {
    let alert = NSAlert()
    alert.messageText = message
    present(alert) { _ in completionHandler() }
  }

  func webView(
    _ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
    completionHandler: @escaping @MainActor @Sendable (Bool) -> Void
  ) {
    let alert = NSAlert()
    alert.messageText = message
    alert.addButton(withTitle: "OK")
    alert.addButton(withTitle: "Cancel")
    present(alert) { completionHandler($0 == .alertFirstButtonReturn) }
  }

  func webView(
    _ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
    initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (String?) -> Void
  ) {
    let alert = NSAlert()
    alert.messageText = prompt
    alert.addButton(withTitle: "OK")
    alert.addButton(withTitle: "Cancel")
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
    field.stringValue = defaultText ?? ""
    alert.accessoryView = field
    alert.window.initialFirstResponder = field
    present(alert, field: field) { completionHandler($0 == .alertFirstButtonReturn ? field.stringValue : nil) }
  }

  private func present(_ alert: NSAlert, field: NSTextField? = nil, then done: @escaping (NSApplication.ModalResponse) -> Void) {
    alert.beginSheetModal(for: window, completionHandler: done)
    #if QT_SELFTEST
      selfTestAnswer(alert, field: field)
    #endif
  }

  func webView(
    _ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo,
    completionHandler: @escaping @MainActor @Sendable ([URL]?) -> Void
  ) {
    #if QT_SELFTEST
      if let file = ProcessInfo.processInfo.environment["QT_SELFTEST_FILE"] { return completionHandler([URL(fileURLWithPath: file)]) }
    #endif
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = parameters.allowsDirectories
    panel.allowsMultipleSelection = parameters.allowsMultipleSelection
    panel.beginSheetModal(for: window) { completionHandler($0 == .OK ? panel.urls : nil) }
  }

  // MARK: Menus

  @objc func stopServerAndQuit() {
    // A server still starting would come up after the app had gone, so wait for it, then stop it.
    if starting {
      quitWhenStarted = true
      return show("Stopping Amber Terminal…")
    }
    guard let origin else { return NSApp.terminate(nil) }
    var request = URLRequest(url: origin.appendingPathComponent("api/shutdown"))
    request.httpMethod = "POST"
    request.setValue("1", forHTTPHeaderField: "x-qt")  // the server only takes writes that carry it
    request.timeoutInterval = 3
    Task {
      _ = try? await URLSession.shared.data(for: request)
      NSApp.terminate(nil)
    }
  }

  @objc private func reload() {
    crashes = 0
    openApp()
  }

  @objc private func actualSize() { webView.pageZoom = 1 }
  @objc private func zoomIn() { webView.pageZoom = min(webView.pageZoom + 0.1, 3) }
  @objc private func zoomOut() { webView.pageZoom = max(webView.pageZoom - 0.1, 0.5) }
  @objc private func openHelp() { NSWorkspace.shared.open(helpURL) }

  private func makeMenu() -> NSMenu {
    let bar = NSMenu()
    func menu(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
      let menu = NSMenu(title: title)
      items.forEach(menu.addItem)
      let holder = NSMenuItem()
      holder.submenu = menu
      bar.addItem(holder)
      return menu
    }
    func item(_ title: String, _ action: Selector, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command, mine: Bool = false) -> NSMenuItem {
      let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
      item.keyEquivalentModifierMask = modifiers
      if mine { item.target = self }
      return item
    }
    _ = menu("Amber Terminal", [
      item("About Amber Terminal", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
      .separator(),
      item("Hide Amber Terminal", #selector(NSApplication.hide(_:)), "h"),
      item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
      item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
      .separator(),
      item("Stop Server and Quit", #selector(stopServerAndQuit), mine: true),
      item("Quit Amber Terminal", #selector(NSApplication.terminate(_:)), "q"),
    ])
    _ = menu("Edit", [
      item("Undo", Selector(("undo:")), "z"),
      item("Redo", Selector(("redo:")), "z", [.command, .shift]),
      .separator(),
      item("Cut", #selector(NSText.cut(_:)), "x"),
      item("Copy", #selector(NSText.copy(_:)), "c"),
      item("Paste", #selector(NSText.paste(_:)), "v"),
      item("Select All", #selector(NSText.selectAll(_:)), "a"),
    ])
    _ = menu("View", [
      item("Reload", #selector(reload), "r", mine: true),
      .separator(),
      item("Actual Size", #selector(actualSize), "0", mine: true),
      item("Zoom In", #selector(zoomIn), "=", mine: true),
      item("Zoom Out", #selector(zoomOut), "-", mine: true),
      .separator(),
      item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
    ])
    NSApp.windowsMenu = menu("Window", [
      item("Close", #selector(NSWindow.performClose(_:)), "w"),
      item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
      item("Zoom", #selector(NSWindow.performZoom(_:))),
      .separator(),
      item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))),
    ])
    NSApp.helpMenu = menu("Help", [item("Amber Terminal Help", #selector(openHelp), mine: true)])
    return bar
  }
}

func activate() {
  if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
}

@main
enum AmberTerminalApp {
  @MainActor static func main() {
    let delegate = AppDelegate()
    NSApplication.shared.delegate = delegate
    NSApplication.shared.setActivationPolicy(.regular)
    NSApplication.shared.run()
  }
}
