import Cocoa
import Darwin
import ObjectiveC
import os
import ScreenSaver
import WebKit

/// Screen saver for Greyline Hub.
///
/// legacyScreenSaver (the host on macOS Sonoma through macOS 27) treats a
/// WKWebView as a hidden, occluded view. The page paints once, then WebContent
/// is suspended and the screen goes black. This view tells WebKit not to do
/// that, keeps a native status line in front of the web view until the shack
/// page is actually drawing, and writes a log the user can send back.

private let saverSubsystem = "com.greylinehub.screensaver"

private final class TickFlag {
    var value = false
}

private enum SaverLog {
    static let logger = Logger(subsystem: saverSubsystem, category: "saver")
    private static let queue = DispatchQueue(label: "com.greylinehub.screensaver.log")
    private static var fileURL: URL?

    static func filePath() -> String {
        queue.sync { resolvedURL().path }
    }

    static func write(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(stamp) \(message)"
        logger.log("\(line, privacy: .public)")
        queue.async {
            let url = resolvedURL()
            let payload = Data((line + "\n").utf8)
            if FileManager.default.fileExists(atPath: url.path),
               let handle = try? FileHandle(forWritingTo: url) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: payload)
                try? handle.close()
            } else {
                try? payload.write(to: url)
            }
        }
    }

    private static func resolvedURL() -> URL {
        if let fileURL { return fileURL }
        let name = "GreylineHub-saver.log"
        let candidates = logCandidates(named: name)
        for url in candidates {
            let directory = url.deletingLastPathComponent()
            if (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil {
                fileURL = url
                return url
            }
        }
        let fallback = URL(fileURLWithPath: "/tmp").appendingPathComponent(name)
        fileURL = fallback
        return fallback
    }

    private static func logCandidates(named name: String) -> [URL] {
        var urls: [URL] = []
        if let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first {
            urls.append(library.appendingPathComponent("Logs", isDirectory: true).appendingPathComponent(name))
        }
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        urls.append(home.appendingPathComponent("Library/Logs", isDirectory: true).appendingPathComponent(name))
        urls.append(home
            .appendingPathComponent("Library/Containers/com.apple.ScreenSaver.Engine.legacyScreenSaver/Data/Library/Logs", isDirectory: true)
            .appendingPathComponent(name))
        return urls
    }
}

private struct ClientConfig: Codable {
    var primaryURL: String
    var secondaryURL: String
    var connectTimeoutSec: Double
    var localServerEnabled: Bool
    var pythonPath: String
    var workingDirectory: String
    var port: Int
    var configPath: String
    var startTimeoutSec: Double

    enum CodingKeys: String, CodingKey {
        case primaryURL = "primary_url"
        case secondaryURL = "secondary_url"
        case connectTimeoutSec = "connect_timeout_sec"
        case localServer = "local_server"
    }

    enum LocalKeys: String, CodingKey {
        case enabled
        case python
        case workingDirectory = "working_directory"
        case port
        case config
        case startTimeoutSec = "start_timeout_sec"
    }

    /// Root URL is the shack page (space weather, bands, map, spots).
    static let fallback = ClientConfig(
        primaryURL: "http://greyline.local:8754/",
        secondaryURL: "http://127.0.0.1:8754/",
        connectTimeoutSec: 1.5,
        localServerEnabled: true,
        pythonPath: "/usr/bin/python3",
        workingDirectory: "",
        port: 8754,
        configPath: "",
        startTimeoutSec: 12
    )

    init(
        primaryURL: String,
        secondaryURL: String,
        connectTimeoutSec: Double,
        localServerEnabled: Bool,
        pythonPath: String,
        workingDirectory: String,
        port: Int,
        configPath: String,
        startTimeoutSec: Double
    ) {
        self.primaryURL = primaryURL
        self.secondaryURL = secondaryURL
        self.connectTimeoutSec = connectTimeoutSec
        self.localServerEnabled = localServerEnabled
        self.pythonPath = pythonPath
        self.workingDirectory = workingDirectory
        self.port = port
        self.configPath = configPath
        self.startTimeoutSec = startTimeoutSec
    }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        let base = ClientConfig.fallback
        primaryURL = try box.decodeIfPresent(String.self, forKey: .primaryURL) ?? base.primaryURL
        secondaryURL = try box.decodeIfPresent(String.self, forKey: .secondaryURL) ?? base.secondaryURL
        connectTimeoutSec = try box.decodeIfPresent(Double.self, forKey: .connectTimeoutSec) ?? base.connectTimeoutSec
        localServerEnabled = base.localServerEnabled
        pythonPath = base.pythonPath
        workingDirectory = base.workingDirectory
        port = base.port
        configPath = base.configPath
        startTimeoutSec = base.startTimeoutSec
        if box.contains(.localServer) {
            let local = try box.nestedContainer(keyedBy: LocalKeys.self, forKey: .localServer)
            localServerEnabled = try local.decodeIfPresent(Bool.self, forKey: .enabled) ?? localServerEnabled
            pythonPath = try local.decodeIfPresent(String.self, forKey: .python) ?? pythonPath
            workingDirectory = try local.decodeIfPresent(String.self, forKey: .workingDirectory) ?? workingDirectory
            port = try local.decodeIfPresent(Int.self, forKey: .port) ?? port
            configPath = try local.decodeIfPresent(String.self, forKey: .config) ?? configPath
            startTimeoutSec = try local.decodeIfPresent(Double.self, forKey: .startTimeoutSec) ?? startTimeoutSec
        }
    }

    func encode(to encoder: Encoder) throws {
        var box = encoder.container(keyedBy: CodingKeys.self)
        try box.encode(primaryURL, forKey: .primaryURL)
        try box.encode(secondaryURL, forKey: .secondaryURL)
        try box.encode(connectTimeoutSec, forKey: .connectTimeoutSec)
        var local = box.nestedContainer(keyedBy: LocalKeys.self, forKey: .localServer)
        try local.encode(localServerEnabled, forKey: .enabled)
        try local.encode(pythonPath, forKey: .python)
        try local.encode(workingDirectory, forKey: .workingDirectory)
        try local.encode(port, forKey: .port)
        try local.encode(configPath, forKey: .config)
        try local.encode(startTimeoutSec, forKey: .startTimeoutSec)
    }
}

@objc(GreylineHubView)
public final class GreylineHubView: ScreenSaverView, WKNavigationDelegate {
    private var webView: WKWebView?
    // Created in init after the first log line. A property initializer would
    // run AppKit before any log, and a crash there leaves no trace.
    private var statusLabel: NSTextField!
    private var config = ClientConfig.fallback
    private var sheet: NSWindow?
    private var primaryField: NSTextField?
    private var secondaryField: NSTextField?
    private var directoryField: NSTextField?
    private var portField: NSTextField?
    private var launchCheckbox: NSButton?
    private var generation = 0
    private var statusLines: [String] = []
    private var sawContent = false
    private var reloadCount = 0
    private var blankStreak = 0
    private var pageIsLoading = false
    private var tickInFlight = false
    private var didTryAdoptSize = false
    private var lastLayoutLog = ""
    private let isPreviewMode: Bool

    override init?(frame: NSRect, isPreview: Bool) {
        SaverLog.write("init enter frame=\(Int(frame.width))x\(Int(frame.height)) preview=\(isPreview)")
        isPreviewMode = isPreview
        super.init(frame: frame, isPreview: isPreview)
        SaverLog.write("init super.init returned")
        animationTimeInterval = 0.5
        configureLayer()
        installStatusLabel()
        SaverLog.write("init done")
    }

    required init?(coder decoder: NSCoder) {
        SaverLog.write("init(coder:) enter")
        isPreviewMode = false
        super.init(coder: decoder)
        SaverLog.write("init(coder:) super.init returned")
        animationTimeInterval = 0.5
        configureLayer()
        installStatusLabel()
        SaverLog.write("init(coder:) done")
    }

    /// Do not paint here. On macOS 26 and later, an opaque draw becomes the
    /// layer's contents and covers the web view a moment after it appears.
    override func draw(_ rect: NSRect) {}

    override func startAnimation() {
        super.startAnimation()
        let version = ProcessInfo.processInfo.operatingSystemVersion
        log("start macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion) preview=\(isPreviewMode) bundle=\(bundleVersion()) frame=\(Int(bounds.width))x\(Int(bounds.height))")
        log("log file \(SaverLog.filePath())")
        didTryAdoptSize = false
        adoptScreenSizeIfNeeded()
        layoutChrome()
        config = loadConfig()
        showStatus("Log: \(SaverLog.filePath())")
        resolveAndLoad()
    }

    override func stopAnimation() {
        generation += 1
        log("stop")
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.removeFromSuperview()
        webView = nil
        super.stopAnimation()
    }

    override func animateOneFrame() {
        guard let webView, !pageIsLoading, !tickInFlight else { return }
        tickInFlight = true
        let token = generation
        let finished = TickFlag()
        let finish: (Any?, Error?) -> Void = { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, self.generation == token, !finished.value else { return }
                finished.value = true
                self.tickInFlight = false
                self.noteTick(result: result, error: error)
            }
        }
        webView.evaluateJavaScript(
            """
            (function () {
              if (typeof window.greylineSaverTick === "function") return window.greylineSaverTick();
              var side = document.getElementById("side");
              return JSON.stringify({
                chars: document.body ? document.body.innerText.length : 0,
                weather: !!(side && side.querySelector(".stat")),
                w: window.innerWidth,
                h: window.innerHeight
              });
            })()
            """
        ) { result, error in
            finish(result, error)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            let error = NSError(
                domain: "GreylineHub",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "the page stopped answering"]
            )
            finish(nil, error)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            if setBool(window, "setWindowOcclusionDetectionEnabled:", false) {
                log("disabled window occlusion detection")
            }
        }
        adoptScreenSizeIfNeeded()
        layoutChrome()
        log("moved to window frame=\(Int(bounds.width))x\(Int(bounds.height))")
    }

    override func layout() {
        super.layout()
        layoutChrome()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutChrome()
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        layoutChrome()
    }

    override var hasConfigureSheet: Bool { true }

    override var configureSheet: NSWindow? {
        if sheet == nil { sheet = buildSheet() }
        let current = loadConfig()
        primaryField?.stringValue = current.primaryURL
        secondaryField?.stringValue = current.secondaryURL
        directoryField?.stringValue = current.workingDirectory
        portField?.stringValue = String(current.port)
        launchCheckbox?.state = current.localServerEnabled ? .on : .off
        return sheet
    }

    private func configureLayer() {
        wantsLayer = true
        // .never left the AppKit status label unpainted. The web view is a
        // subview, and draw(_:) stays empty so a redraw does not cover it.
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.backgroundColor = NSColor(srgbRed: 0.03, green: 0.04, blue: 0.05, alpha: 1).cgColor
    }

    override var isOpaque: Bool { false }

    private func installStatusLabel() {
        statusLabel = NSTextField(wrappingLabelWithString: "")
        let background = NSColor(srgbRed: 0.03, green: 0.04, blue: 0.05, alpha: 1)
        statusLabel.textColor = NSColor(srgbRed: 0.93, green: 0.90, blue: 0.82, alpha: 1)
        statusLabel.font = NSFont.monospacedSystemFont(ofSize: isPreviewMode ? 11 : 22, weight: .medium)
        statusLabel.alignment = .left
        statusLabel.maximumNumberOfLines = 0
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.drawsBackground = true
        statusLabel.backgroundColor = background
        statusLabel.isBezeled = false
        statusLabel.isEditable = false
        statusLabel.isSelectable = false
        statusLabel.wantsLayer = true
        statusLabel.layer?.backgroundColor = background.cgColor
        addSubview(statusLabel)
    }

    private func adoptScreenSizeIfNeeded() {
        guard !didTryAdoptSize, bounds.width < 2 || bounds.height < 2 else { return }
        let size = resolvedScreenSize()
        guard size.width > 2, size.height > 2, size != bounds.size else { return }
        didTryAdoptSize = true
        log("adopting screen size \(Int(size.width))x\(Int(size.height)) in place of \(Int(bounds.width))x\(Int(bounds.height))")
        setFrameSize(size)
    }

    private func resolvedScreenSize() -> NSSize {
        let size = window?.screen?.frame.size ?? NSScreen.main?.frame.size ?? .zero
        if size.width > 2, size.height > 2 { return size }
        return NSSize(width: 1280, height: 800)
    }

    private func layoutChrome() {
        adoptScreenSizeIfNeeded()
        let frame = webViewTargetFrame()
        webView?.frame = frame
        let pad = min(isPreviewMode ? 12 : 48, max(8, frame.width / 10))
        var labelFrame = frame.insetBy(dx: pad, dy: pad)
        if labelFrame.width < 40 || labelFrame.height < 40 {
            labelFrame = frame
        }
        statusLabel.frame = labelFrame
        statusLabel.preferredMaxLayoutWidth = max(40, labelFrame.width)
        if !statusLabel.isHidden {
            addSubview(statusLabel)
            statusLabel.needsDisplay = true
            statusLabel.displayIfNeeded()
        }
        let note = "layout web=\(Int(frame.width))x\(Int(frame.height)) label=\(Int(labelFrame.width))x\(Int(labelFrame.height)) hidden=\(statusLabel.isHidden)"
        if note != lastLayoutLog {
            lastLayoutLog = note
            log(note)
        }
    }

    /// Preview uses the thumbnail bounds. A full-screen saver uses the view's
    /// bounds once they are real, and the display size when the host still
    /// has the view at 0×0.
    private func webViewTargetFrame() -> NSRect {
        if isPreviewMode, bounds.width > 2, bounds.height > 2 {
            return bounds
        }
        let screen = resolvedScreenSize()
        if bounds.width > 2, bounds.height > 2 {
            return NSRect(
                x: 0,
                y: 0,
                width: min(bounds.width, screen.width),
                height: min(bounds.height, screen.height)
            )
        }
        return NSRect(origin: .zero, size: screen)
    }

    private func resolveAndLoad() {
        generation += 1
        let token = generation
        sawContent = false
        reloadCount = 0
        blankStreak = 0
        let timeout = max(0.4, config.connectTimeoutSec)
        showStatus("Trying home server \(config.primaryURL)")
        showStatus(pageDescription(config.primaryURL))
        probe(config.primaryURL, timeout: timeout) { [weak self] result in
            guard let self, self.generation == token else { return }
            if result.ok {
                self.loadPage(self.config.primaryURL)
                return
            }
            self.showStatus("Home server did not answer: \(result.detail)")
            self.showStatus("Trying this Mac \(self.config.secondaryURL)")
            self.showStatus(self.pageDescription(self.config.secondaryURL))
            self.probe(self.config.secondaryURL, timeout: timeout) { secondary in
                guard self.generation == token else { return }
                if secondary.ok {
                    self.loadPage(self.config.secondaryURL)
                    return
                }
                self.showStatus("This Mac did not answer: \(secondary.detail)")
                self.startLocalServerThenPoll(token: token)
            }
        }
    }

    private func startLocalServerThenPoll(token: Int) {
        guard config.localServerEnabled else {
            showStatus("Failed: the local Python server is turned off in Screen Saver options.")
            return
        }
        let directory = (config.workingDirectory as NSString).expandingTildeInPath
        guard !directory.isEmpty, FileManager.default.fileExists(atPath: directory) else {
            showStatus("Failed: set the Greyline Hub folder in Screen Saver options, or install the LaunchAgent so localhost is already running.")
            return
        }
        let started = launchServer(in: directory)
        if started {
            showStatus("Started Python. Waiting for \(config.secondaryURL)")
        } else {
            showStatus("Could not start Python from the screen saver (the sandbox often blocks this). Waiting anyway in case it is already running.")
        }
        pollSecondary(attemptsLeft: Int(max(4, config.startTimeoutSec / 0.4)), token: token)
    }

    private func pollSecondary(attemptsLeft: Int, token: Int) {
        guard generation == token else { return }
        if attemptsLeft <= 0 {
            showStatus("Failed: \(config.secondaryURL) never answered.")
            showStatus("Install the LaunchAgent (clients/macos/install-local-server.sh) and try again.")
            return
        }
        probe(config.secondaryURL, timeout: 0.8) { [weak self] result in
            guard let self, self.generation == token else { return }
            if result.ok {
                self.loadPage(self.config.secondaryURL)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                self.pollSecondary(attemptsLeft: attemptsLeft - 1, token: token)
            }
        }
    }

    private func launchServer(in directory: String) -> Bool {
        let support = configDirectory()
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let lockURL = support.appendingPathComponent("server.lock")
        FileManager.default.createFile(atPath: lockURL.path, contents: nil)
        let fd = open(lockURL.path, O_RDWR)
        if fd >= 0 {
            if flock(fd, LOCK_EX | LOCK_NB) != 0 {
                close(fd)
                log("another screen is already starting Python")
                return false
            }
            defer {
                flock(fd, LOCK_UN)
                close(fd)
            }
            return spawnPython(in: directory)
        }
        return spawnPython(in: directory)
    }

    private func spawnPython(in directory: String) -> Bool {
        let python = resolvePython(config.pythonPath)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        var arguments = ["-m", "greyline_hub", "--port", String(config.port)]
        if !config.configPath.isEmpty {
            arguments += ["--config", (config.configPath as NSString).expandingTildeInPath]
        }
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        log("spawn \(python) \(arguments.joined(separator: " ")) in \(directory)")
        do {
            try process.run()
            log("python pid \(process.processIdentifier)")
            return true
        } catch {
            log("python failed: \(error.localizedDescription)")
            showStatus("Failed to start Python: \(error.localizedDescription)")
            return false
        }
    }

    private func resolvePython(_ preferred: String) -> String {
        let candidates = [preferred, "/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"]
        for path in candidates where !path.isEmpty && FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return preferred.isEmpty ? "/usr/bin/python3" : preferred
    }

    private struct ProbeResult {
        var ok: Bool
        var detail: String
    }

    private func probe(_ urlString: String, timeout: TimeInterval, done: @escaping (ProbeResult) -> Void) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme, scheme == "http" || scheme == "https" else {
            DispatchQueue.main.async { done(ProbeResult(ok: false, detail: "URL is not http or https")) }
            return
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.timeoutInterval = timeout
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        let task = session.dataTask(with: request) { _, response, error in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let ok = error == nil && (200..<400).contains(code)
            let detail: String
            if let error {
                detail = error.localizedDescription
            } else if !ok {
                detail = "HTTP \(code)"
            } else {
                detail = "HTTP \(code)"
            }
            session.invalidateAndCancel()
            DispatchQueue.main.async {
                done(ProbeResult(ok: ok, detail: detail))
            }
        }
        task.resume()
    }

    private func loadPage(_ urlString: String) {
        let frame = webViewTargetFrame()
        if bounds.width < 2 || bounds.height < 2 {
            setFrameSize(frame.size)
        }
        let web = ensureWebView(frame: frame)
        guard let url = URL(string: urlString) else {
            showStatus("Failed: the dashboard URL is not valid.")
            return
        }
        log("load \(urlString) frame=\(Int(frame.width))x\(Int(frame.height)) \(pageDescription(urlString))")
        showStatus("Loading \(pageDescription(urlString))")
        showStatus(urlString)
        pageIsLoading = true
        web.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
    }

    private func ensureWebView(frame: NSRect) -> WKWebView {
        if let webView { return webView }
        let configuration = WKWebViewConfiguration()
        let script = WKUserScript(
            source: """
            try {
              Object.defineProperty(Document.prototype, "hidden", {
                configurable: true, get: function () { return false; }
              });
              Object.defineProperty(Document.prototype, "visibilityState", {
                configurable: true, get: function () { return "visible"; }
              });
            } catch (e) {}
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        configuration.userContentController.addUserScript(script)
        let web = WKWebView(frame: frame, configuration: configuration)
        web.navigationDelegate = self
        if #available(macOS 12.0, *) {
            web.underPageBackgroundColor = .black
        }
        if #available(macOS 13.3, *) {
            web.isInspectable = true
        }
        if setBool(web, "_setWindowOcclusionDetectionEnabled:", false) {
            log("disabled WKWebView occlusion detection")
        } else {
            log("WKWebView occlusion selector is missing; the page may go black")
        }
        if setBool(web, "_setAlwaysRunsAtForegroundPriority:", true) {
            log("requested foreground WebContent priority (no effect on macOS 26 and later)")
        }
        addSubview(web)
        webView = web
        layoutChrome()
        return web
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageIsLoading = false
        log("page finished \(webView.url?.absoluteString ?? "")")
        showStatus("Page loaded. Waiting for it to draw.")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        pageIsLoading = false
        let text = error.localizedDescription
        log("navigation failed: \(text)")
        if (error as NSError).code == NSURLErrorCancelled { return }
        showStatus("Failed: \(text)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        pageIsLoading = false
        let text = error.localizedDescription
        log("provisional navigation failed: \(text)")
        if (error as NSError).code == NSURLErrorCancelled { return }
        showStatus("Failed: \(text)")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        log("WebContent process terminated")
        handleBlank("WebContent process terminated")
    }

    private func noteTick(result: Any?, error: Error?) {
        if let error {
            blankStreak += 1
            log("tick failed (\(blankStreak)): \(error.localizedDescription)")
            if blankStreak >= 2 {
                handleBlank(error.localizedDescription)
            }
            return
        }
        let text = result as? String ?? ""
        let chars = jsonInt(text, key: "chars") ?? 0
        if chars > 40 {
            if !sawContent {
                log("page is drawing (\(chars) characters) \(text)")
            }
            sawContent = true
            blankStreak = 0
            hideStatus()
            return
        }
        blankStreak += 1
        if blankStreak >= 2 {
            log("page has no text (\(chars) characters) \(text)")
            handleBlank(sawContent ? "the page went blank after it had drawn" : "the page never drew")
        }
    }

    private func handleBlank(_ reason: String) {
        showStatus("Failed: \(reason)")
        showStatus("macOS suspends a web view inside a screen saver. This build asks WebKit not to do that.")
        guard reloadCount < 1, let webView else { return }
        reloadCount += 1
        blankStreak = 0
        showStatus("Reloading the page once.")
        log("reloading after blank")
        pageIsLoading = true
        webView.reload()
    }

    private func showStatus(_ line: String) {
        log(line)
        statusLines.append(line)
        if statusLines.count > 14 {
            statusLines.removeFirst(statusLines.count - 14)
        }
        statusLabel.stringValue = "Greyline Hub \(bundleVersion())\n" + statusLines.joined(separator: "\n")
        statusLabel.isHidden = false
        layoutChrome()
        addSubview(statusLabel)
        statusLabel.needsDisplay = true
        statusLabel.displayIfNeeded()
    }

    private func hideStatus() {
        statusLabel.isHidden = true
    }

    private func log(_ message: String) {
        SaverLog.write(message)
    }

    private func pageDescription(_ urlString: String) -> String {
        let path = URL(string: urlString)?.path ?? "/"
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmed.isEmpty || trimmed == "index.html" {
            return "Shack page: space weather, HF bands, map, and spots."
        }
        if trimmed == "map" || trimmed.hasSuffix("/map") {
            return "Map page: no space weather panel. Use / for the shack page."
        }
        return "Page /\(trimmed)/"
    }

    private func bundleVersion() -> String {
        let bundle = Bundle(for: GreylineHubView.self)
        let short = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(short) (\(build))"
    }

    private func jsonInt(_ json: String, key: String) -> Int? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let number = object[key] as? Int { return number }
        if let number = object[key] as? Double { return Int(number) }
        return nil
    }

    /// BOOL-taking WebKit and AppKit setters are private. Skip them when the
    /// selector is gone so a future OS does not crash the saver.
    @discardableResult
    private func setBool(_ object: NSObject, _ name: String, _ value: Bool) -> Bool {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector),
              let method = class_getInstanceMethod(type(of: object), selector) else {
            return false
        }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(method_getImplementation(method), to: Setter.self)(object, selector, value)
        return true
    }

    private func configDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("GreylineHub", isDirectory: true)
    }

    private func configURL() -> URL {
        configDirectory().appendingPathComponent("client.json")
    }

    private func loadConfig() -> ClientConfig {
        let url = configURL()
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            log("no client.json at \(url.path); using the shack page")
            return .fallback
        }
        let decoder = JSONDecoder()
        guard let decoded = try? decoder.decode(ClientConfig.self, from: Data(stripJSONComments(text).utf8)) else {
            log("could not read \(url.path); using the shack page")
            return .fallback
        }
        log("config \(url.path) primary=\(decoded.primaryURL) secondary=\(decoded.secondaryURL)")
        return decoded
    }

    private func saveConfig(_ value: ClientConfig) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        let directory = configDirectory()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: configURL())
        log("wrote \(configURL().path)")
    }

    private func stripJSONComments(_ text: String) -> String {
        var out = ""
        var index = text.startIndex
        var inString = false
        var escaped = false
        while index < text.endIndex {
            let character = text[index]
            if inString {
                out.append(character)
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
                index = text.index(after: index)
                continue
            }
            if character == "\"" {
                inString = true
                out.append(character)
                index = text.index(after: index)
                continue
            }
            let next = text.index(after: index)
            if character == "/", next < text.endIndex, text[next] == "/" {
                index = next
                while index < text.endIndex, text[index] != "\n" {
                    index = text.index(after: index)
                }
                continue
            }
            if character == "/", next < text.endIndex, text[next] == "*" {
                index = text.index(after: next)
                while index < text.endIndex {
                    let after = text.index(after: index)
                    if text[index] == "*", after < text.endIndex, text[after] == "/" {
                        index = text.index(after: after)
                        break
                    }
                    index = after
                }
                continue
            }
            out.append(character)
            index = next
        }
        return out
    }

    private func buildSheet() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.title = "Greyline Hub"
        guard let content = window.contentView else { return window }

        func label(_ text: String, _ frame: NSRect) {
            let field = NSTextField(labelWithString: text)
            field.frame = frame
            field.textColor = .secondaryLabelColor
            content.addSubview(field)
        }
        func input(_ frame: NSRect) -> NSTextField {
            let field = NSTextField(frame: frame)
            content.addSubview(field)
            return field
        }

        label("Primary URL. The shack page ends in /. /map/ hides space weather.", NSRect(x: 20, y: 250, width: 520, height: 18))
        primaryField = input(NSRect(x: 20, y: 224, width: 520, height: 24))
        label("Secondary URL on this Mac, used when the home server is down", NSRect(x: 20, y: 196, width: 520, height: 18))
        secondaryField = input(NSRect(x: 20, y: 170, width: 520, height: 24))
        label("Greyline Hub folder, used only if the secondary URL is down", NSRect(x: 20, y: 142, width: 400, height: 18))
        directoryField = input(NSRect(x: 20, y: 116, width: 420, height: 24))
        label("Port", NSRect(x: 450, y: 142, width: 80, height: 18))
        portField = input(NSRect(x: 450, y: 116, width: 90, height: 24))

        let checkbox = NSButton(checkboxWithTitle: "Start the local Python server when localhost is down", target: nil, action: nil)
        checkbox.frame = NSRect(x: 20, y: 78, width: 460, height: 22)
        content.addSubview(checkbox)
        launchCheckbox = checkbox

        let hint = NSTextField(wrappingLabelWithString: "A blank screen is a WebKit suspension. Status text stays on screen, and the log is listed there.")
        hint.frame = NSRect(x: 20, y: 48, width: 520, height: 28)
        hint.textColor = .secondaryLabelColor
        hint.font = NSFont.systemFont(ofSize: 11)
        content.addSubview(hint)

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelSheet))
        cancel.frame = NSRect(x: 350, y: 12, width: 90, height: 28)
        cancel.bezelStyle = .rounded
        content.addSubview(cancel)
        let save = NSButton(title: "Save", target: self, action: #selector(saveSheet))
        save.frame = NSRect(x: 448, y: 12, width: 90, height: 28)
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"
        content.addSubview(save)
        return window
    }

    @objc private func cancelSheet() { endSheet() }

    @objc private func saveSheet() {
        var next = loadConfig()
        next.primaryURL = primaryField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? next.primaryURL
        next.secondaryURL = secondaryField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? next.secondaryURL
        next.workingDirectory = directoryField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let port = Int(portField?.stringValue ?? ""), (0...65535).contains(port) {
            next.port = port
        }
        next.localServerEnabled = launchCheckbox?.state == .on
        saveConfig(next)
        config = next
        endSheet()
        resolveAndLoad()
    }

    private func endSheet() {
        guard let sheet else { return }
        if let parent = sheet.sheetParent {
            parent.endSheet(sheet)
        } else {
            sheet.orderOut(nil)
        }
    }
}
