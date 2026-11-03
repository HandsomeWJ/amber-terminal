// Test builds only (compiled with -D QT_SELFTEST by macos/selftest.sh, never into the real app).
// Once the app page loads, this clicks through it the way a person would, writes what happened to
// $QT_SELFTEST_OUT/report.json with two snapshots, then uses Stop Server and Quit.
#if QT_SELFTEST
  import AppKit
  import WebKit

  @MainActor
  enum SelfTest {
    static var started = false
    static var answers = (ProcessInfo.processInfo.environment["QT_SELFTEST_ANSWERS"] ?? "")
      .split(separator: "|").map(String.init)
    static var links: [String] = []
    static var dialogs: [String] = []
    static var missing: [String] = []
    static let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["QT_SELFTEST_OUT"] ?? NSTemporaryDirectory())
  }

  extension AppDelegate {
    var selfTestErrorCapture: WKUserScript {
      WKUserScript(
        source: """
          window.__qtErrors = [];
          addEventListener("error", (e) => __qtErrors.push(String(e.message)));
          addEventListener("unhandledrejection", (e) => __qtErrors.push(String(e.reason)));
          addEventListener("securitypolicyviolation", (e) => __qtErrors.push(`CSP ${e.violatedDirective} ${e.blockedURI}`));
          """, injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }

    func selfTestRecordLink(_ url: URL) { SelfTest.links.append(url.absoluteString) }

    // No screen uses alert, confirm or prompt yet. If one does, this answers it with the next entry
    // of $QT_SELFTEST_ANSWERS: text for a prompt, "ok" or "cancel" for a confirm.
    func selfTestAnswer(_ alert: NSAlert, field: NSTextField?) {
      let answer = SelfTest.answers.isEmpty ? "ok" : SelfTest.answers.removeFirst()
      SelfTest.dialogs.append("\(alert.messageText) -> \(answer)")
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
        field?.stringValue = answer
        let ok = field != nil || answer != "cancel"
        self.window.endSheet(alert.window, returnCode: ok ? .alertFirstButtonReturn : .alertSecondButtonReturn)
      }
    }

    func selfTestStart() {
      // Only macos/selftest.sh sets this; without it a test build does nothing on its own.
      guard !SelfTest.started, ProcessInfo.processInfo.environment["QT_SELFTEST_OUT"] != nil else { return }
      SelfTest.started = true
      Task { await selfTestRun() }
    }

    private func js(_ body: String) async -> Any? {
      do { return try await webView.callAsyncJavaScript(body, contentWorld: .page) } catch { return "JS error: \(error)" }
    }

    private func pause(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) }

    /// Clicks the element from script. WebKit runs callAsyncJavaScript as a user gesture, so file
    /// pickers, new windows and downloads behave as they do for a person's click. (Synthesised mouse
    /// events don't work here: a window opened in the background takes its first click to activate.)
    private func click(_ selector: String) async {
      let found = await js("const el = document.querySelector(\(json(selector))); if (!el) return false; el.click(); return true")
      if found as? Bool != true { SelfTest.missing.append(selector) }
    }

    private func json(_ s: String) -> String {
      String(data: try! JSONSerialization.data(withJSONObject: [s]), encoding: .utf8)!.dropFirst().dropLast().description
    }

    private func snapshot(_ name: String) async {
      guard let image = try? await webView.takeSnapshot(configuration: nil), let tiff = image.tiffRepresentation,
        let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
      else { return }
      try? png.write(to: SelfTest.out.appendingPathComponent(name))
    }

    private func selfTestRun() async {
      var report: [String: Any] = ["serverWasRunning": serverWasRunning, "origin": origin?.absoluteString ?? ""]
      await pause(6)
      // The copy buttons (PLAY, ASK) need the Clipboard API, which only a secure context has. Copying
      // for real would overwrite your clipboard, so this checks that the API is there.
      report["loaded"] = await js("""
        return { title: document.title, panels: [...document.querySelectorAll(".ptitle .fn")].map((e) => e.textContent),
          tableRows: [...document.querySelectorAll(".pbody")].map((b) => b.querySelectorAll("tr").length),
          notification: typeof Notification, permission: Notification.permission,
          clipboard: isSecureContext && typeof navigator.clipboard?.writeText,
          inlineScripts: document.querySelectorAll("script:not([src])").length }
        """)
      await snapshot("1-loaded.png")

      await click(".pbtn[data-a=export]")  // panel 1's tables as one CSV file
      await pause(2)
      report["downloads"] = (try? FileManager.default.contentsOfDirectory(atPath: downloadsFolder.path))?.sorted() ?? []

      await click("a.toplink[target=_blank]")  // Help: opens in the browser, the window stays on the app
      await pause(0.8)
      report["links"] = SelfTest.links
      report["stillOnApp"] = webView.url?.absoluteString ?? ""

      // PORT IMPORT in panel 3: the file picker hands over $QT_SELFTEST_FILE, then "Read it" parses it.
      _ = await js("await amber.run('PORT IMPORT', 2); return true")
      await pause(2)
      await click("input[type=file]")
      await pause(1.5)
      report["imported"] = await js("return document.querySelector('.panel textarea')?.value.split('\\n')[0]") ?? ""
      await click("[data-read]")
      await pause(1.5)
      report["preview"] = await js("return document.querySelector('[data-preview]')?.textContent.slice(0, 200)") ?? ""

      report["dialogs"] = SelfTest.dialogs
      report["missing"] = SelfTest.missing
      report["errors"] = await js("return window.__qtErrors") ?? []
      await snapshot("2-after.png")

      if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: SelfTest.out.appendingPathComponent("report.json"))
      }
      stopServerAndQuit()
    }
  }
#endif
