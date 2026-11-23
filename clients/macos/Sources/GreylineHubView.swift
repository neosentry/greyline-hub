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

/// Serves the published site from disk. legacyScreenSaver blocks every
/// outgoing socket, including 127.0.0.1, so the page cannot be loaded over HTTP.
private final class LocalSiteHandler: NSObject, WKURLSchemeHandler {
    var root: URL?
    private var stopped = Set<ObjectIdentifier>()
    private let lock = NSLock()

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let identity = ObjectIdentifier(urlSchemeTask as AnyObject)
        guard let url = urlSchemeTask.request.url, let root else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        let relative = (url.path.isEmpty || url.path == "/") ? "index.html" : String(url.path.dropFirst())
        let file = root.appendingPathComponent(relative).standardizedFileURL
        let rootPath = root.standardizedFileURL.path
        let filePath = file.path
        guard filePath == rootPath || filePath.hasPrefix(rootPath + "/") else {
            urlSchemeTask.didFailWithError(URLError(.noPermissionsToReadFile))
            return
        }
        guard let data = try? Data(contentsOf: file) else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let mime: String
        switch file.pathExtension.lowercased() {
        case "html": mime = "text/html; charset=utf-8"
        case "css": mime = "text/css; charset=utf-8"
        case "js": mime = "text/javascript; charset=utf-8"
        case "json", "geojson": mime = "application/json; charset=utf-8"
        default: mime = "application/octet-stream"
        }
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": mime,
                "Content-Length": String(data.count),
                "Cache-Control": "no-store",
                "Access-Control-Allow-Origin": "*",
            ]
        ) else {
            urlSchemeTask.didFailWithError(URLError(.badServerResponse))
            return
        }
        lock.lock()
        let cancelled = stopped.contains(identity)
        lock.unlock()
        if cancelled { return }
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        lock.lock()
        stopped.insert(ObjectIdentifier(urlSchemeTask as AnyObject))
        lock.unlock()
    }
}

enum SaverLog {
    private static let unified = OSLog(subsystem: saverSubsystem, category: "saver")
    private static let queue = DispatchQueue(label: "com.greylinehub.screensaver.log")
    private static var fileURL: URL?

    static func filePath() -> String {
        queue.sync { resolvedURL().path }
    }

    static func write(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        // The word "greyline" is literal so a case-sensitive grep finds it.
        // .error is recorded at the default log level. %{public}@ keeps the
        // text from being redacted as <private>.
        let line = "\(stamp) \(message)"
        os_log("greyline %{public}@", log: unified, type: .error, line)
        os_log("greyline %{public}@", log: .default, type: .error, line)
        NSLog("%@", "greyline \(line)")
        queue.async {
            let url = resolvedURL()
            let payload = Data(("greyline \(line)\n").utf8)
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
        // Inside legacyScreenSaver this is the container, which the sandbox allows.
        let containerHome = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        urls.append(containerHome.appendingPathComponent("Library/Logs", isDirectory: true).appendingPathComponent(name))
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
    /// "native" draws in this view. "webkit" is the old page, which macOS 26 and 27 blank.
    var renderer: String

    enum CodingKeys: String, CodingKey {
        case primaryURL = "primary_url"
        case secondaryURL = "secondary_url"
        case connectTimeoutSec = "connect_timeout_sec"
        case localServer = "local_server"
        case renderer
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
        connectTimeoutSec: 4,
        localServerEnabled: true,
        pythonPath: "/usr/bin/python3",
        workingDirectory: "",
        port: 8754,
        configPath: "",
        startTimeoutSec: 12,
        renderer: "native"
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
        startTimeoutSec: Double,
        renderer: String
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
        self.renderer = renderer
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
        renderer = try box.decodeIfPresent(String.self, forKey: .renderer) ?? base.renderer
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
        try box.encode(renderer, forKey: .renderer)
    }
}

private extension Notification.Name {
    static let greylineFrame = Notification.Name("GreylineHubFrame")
}

/// One web view for every screen. legacyScreenSaver builds two views (the log
/// showed webPageID 36 and 114), and each one was suspended.
private final class PageHost {
    static let shared = PageHost()
    let handler = LocalSiteHandler()
    var webView: WKWebView?
    var image: NSImage?
    var creating = false
    var loadStarted = false
    var clients = Set<ObjectIdentifier>()
    private var parkWindow: NSWindow?

    func holdOffscreen(_ web: WKWebView) {
        if parkWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: -20000, y: -20000, width: 1440, height: 900),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.ignoresMouseEvents = true
            parkWindow = window
        }
        parkWindow?.contentView?.addSubview(web)
        web.frame = parkWindow?.contentView?.bounds ?? web.frame
    }
}

@objc(GreylineHubView)
final class GreylineHubView: ScreenSaverView, WKNavigationDelegate {
    private var webView: WKWebView?
    private var loadedLocalFile = false
    // Created in init after the first log line. A property initializer would
    // run AppKit before any log, and a crash there leaves no trace.
    private var statusLabel: NSTextField!
    private var snapshotView: NSImageView!
    private var lastGoodImage: NSImage?
    private var snapshotInFlight = false
    private var blankSnapshots = 0
    private var config = ClientConfig.fallback
    private var sheet: NSWindow?
    private var primaryField: NSTextField?
    private var secondaryField: NSTextField?
    private var directoryField: NSTextField?
    private var portField: NSTextField?
    private var launchCheckbox: NSButton?
    private var webkitCheckbox: NSButton?
    private let nativeBoard = NativeDashboard()
    private var useNative = true
    private var generation = 0
    private var statusLines: [String] = []
    private var sawContent = false
    private var reloadCount = 0
    private var pageIsLoading = false
    private var didTryAdoptSize = false
    private var lastLayoutLog = ""
    private let isPreviewMode: Bool

    override init?(frame: NSRect, isPreview: Bool) {
        SaverLog.write("init enter frame=\(Int(frame.width))x\(Int(frame.height)) preview=\(isPreview)")
        isPreviewMode = isPreview
        super.init(frame: frame, isPreview: isPreview)
        SaverLog.write("init super.init returned")
        animationTimeInterval = 1
        config = loadConfig()
        useNative = config.renderer != "webkit"
        if useNative {
            wantsLayer = false
            SaverLog.write("init native \(bundleVersion())")
        } else {
            configureLayer()
            installStatusLabel()
            NotificationCenter.default.addObserver(self, selector: #selector(sharedFrameChanged), name: .greylineFrame, object: nil)
        }
        SaverLog.write("init done")
    }

    required init?(coder decoder: NSCoder) {
        SaverLog.write("init(coder:) enter")
        isPreviewMode = false
        super.init(coder: decoder)
        SaverLog.write("init(coder:) super.init returned")
        animationTimeInterval = 1
        config = loadConfig()
        useNative = config.renderer != "webkit"
        if useNative {
            wantsLayer = false
            SaverLog.write("init native \(bundleVersion())")
        } else {
            configureLayer()
            installStatusLabel()
            NotificationCenter.default.addObserver(self, selector: #selector(sharedFrameChanged), name: .greylineFrame, object: nil)
        }
        SaverLog.write("init(coder:) done")
    }

    /// Paint the last good page bitmap ourselves. WebKit's own layers are
    /// marked volatile by legacyScreenSaver and go clear after about a second.
    override func draw(_ rect: NSRect) {
        if useNative {
            wantsLayer = false
            nativeBoard.draw(in: bounds)
            return
        }
        let image = PageHost.shared.image ?? lastGoodImage
        guard let image else { return }
        image.draw(in: bounds, from: .zero, operation: .copy, fraction: 1)
    }

    override func startAnimation() {
        super.startAnimation()
        let version = ProcessInfo.processInfo.operatingSystemVersion
        log("start macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion) preview=\(isPreviewMode) bundle=\(bundleVersion()) frame=\(Int(bounds.width))x\(Int(bounds.height))")
        log("log file \(SaverLog.filePath())")
        didTryAdoptSize = false
        config = loadConfig()
        useNative = config.renderer != "webkit"
        if useNative {
            wantsLayer = false
            log("native dashboard \(bundleVersion()) preview=\(isPreviewMode) frame=\(Int(bounds.width))x\(Int(bounds.height)) no WebKit")
            nativeBoard.configure(mapOnly: isMapURL(config.primaryURL), version: bundleVersion())
            nativeBoard.reload(force: true)
            needsDisplay = true
            return
        }
        if statusLabel == nil {
            configureLayer()
            installStatusLabel()
        }
        adoptScreenSizeIfNeeded()
        layoutChrome()
        showStatus("Log: \(SaverLog.filePath())")
        PageHost.shared.clients.insert(ObjectIdentifier(self))
        resolveAndLoad()
    }

    override func stopAnimation() {
        if useNative {
            log("native stop")
            super.stopAnimation()
            return
        }
        generation += 1
        let remaining = PageHost.shared.clients
        PageHost.shared.clients.remove(ObjectIdentifier(self))
        log("stop clients=\(PageHost.shared.clients.count) heldSnapshot=\(PageHost.shared.image != nil)")
        if PageHost.shared.clients.isEmpty {
            webView?.stopLoading()
            webView?.navigationDelegate = nil
            webView?.removeFromSuperview()
            if PageHost.shared.webView === webView {
                PageHost.shared.webView = nil
                PageHost.shared.loadStarted = false
            }
        } else if let webView, webView.superview === self {
            log("dedupe: moving the single web view off this screen, \(PageHost.shared.clients.count) still active")
            PageHost.shared.holdOffscreen(webView)
        }
        _ = remaining
        webView = nil
        super.stopAnimation()
    }

    @objc private func sharedFrameChanged() {
        lastGoodImage = PageHost.shared.image
        if lastGoodImage != nil {
            hideStatus()
        }
        needsDisplay = true
    }

    override func animateOneFrame() {
        if useNative {
            nativeBoard.reload(force: false)
            needsDisplay = true
            return
        }
        if webView == nil {
            if let image = PageHost.shared.image {
                lastGoodImage = image
                needsDisplay = true
            }
            return
        }
        guard let webView, !pageIsLoading, !snapshotInFlight else { return }
        if webView.superview == nil {
            log("DISAPPEAR: web view was detached; re-attaching")
            addSubview(webView)
            layoutChrome()
        }
        snapshotInFlight = true
        let token = generation
        webView.evaluateJavaScript("window.greylineSaverTick && window.greylineSaverTick()", completionHandler: nil)
        let configuration = WKSnapshotConfiguration()
        let size = webView.bounds.size
        configuration.rect = CGRect(origin: .zero, size: size)
        configuration.afterScreenUpdates = lastGoodImage == nil
        webView.takeSnapshot(with: configuration) { [weak self] image, error in
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                self.snapshotInFlight = false
                self.noteSnapshot(image, error: error)
            }
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
        guard !useNative else { return }
        layoutChrome()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard !useNative else {
            needsDisplay = true
            return
        }
        layoutChrome()
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        guard !useNative else { return }
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
        webkitCheckbox?.state = current.renderer == "webkit" ? .on : .off
        return sheet
    }

    private func configureLayer() {
        wantsLayer = true
        // .never left the AppKit status label unpainted. The web view is a
        // subview, and draw(_:) stays empty so a redraw does not cover it.
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.backgroundColor = NSColor(srgbRed: 0.03, green: 0.04, blue: 0.05, alpha: 1).cgColor
    }

    override var isOpaque: Bool { useNative }

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
        snapshotView = NSImageView()
        snapshotView.imageScaling = .scaleAxesIndependently
        snapshotView.imageAlignment = .alignCenter
        snapshotView.wantsLayer = true
        snapshotView.layerContentsRedrawPolicy = .onSetNeedsDisplay
        snapshotView.isHidden = true
        addSubview(snapshotView)
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
        guard !useNative, statusLabel != nil else { return }
        adoptScreenSizeIfNeeded()
        let frame = webViewTargetFrame()
        if PageHost.shared.image != nil, let webView {
            let size = frame.size
            webView.frame = NSRect(x: 0, y: -size.height - 30, width: max(size.width, 2), height: max(size.height, 2))
        } else {
            webView?.frame = frame
        }
        snapshotView?.frame = frame
        let pad = min(isPreviewMode ? 12 : 48, max(8, frame.width / 10))
        var labelFrame = frame.insetBy(dx: pad, dy: pad)
        if labelFrame.width < 40 || labelFrame.height < 40 {
            labelFrame = frame
        }
        statusLabel.frame = labelFrame
        statusLabel.preferredMaxLayoutWidth = max(40, labelFrame.width)
        if snapshotView?.isHidden == false {
            addSubview(snapshotView)
        }
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
        let timeout = max(4, config.connectTimeoutSec)
        if PageHost.shared.loadStarted {
            log("dedupe: not loading a second web view, clients=\(PageHost.shared.clients.count)")
            if let image = PageHost.shared.image {
                lastGoodImage = image
                hideStatus()
                needsDisplay = true
            }
            return
        }
        PageHost.shared.loadStarted = true
        if let site = findPublishedSite() {
            loadLocalSite(site)
        } else {
            showStatus("No local shack page yet. The screen saver sandbox blocks network, including 127.0.0.1.")
        }
        showStatus("Trying home server \(config.primaryURL) (\(Int(timeout))s)")
        showStatus(pageDescription(config.primaryURL))
        probe(config.primaryURL, timeout: timeout) { [weak self] result in
            guard let self, self.generation == token else { return }
            if result.ok {
                self.loadPage(self.config.primaryURL)
                return
            }
            self.noteNetworkFailure("Home server did not answer: \(result.detail)")
            self.noteNetworkFailure("Trying this Mac \(self.config.secondaryURL)")
            self.probe(self.config.secondaryURL, timeout: timeout) { secondary in
                guard self.generation == token else { return }
                if secondary.ok {
                    self.loadPage(self.config.secondaryURL)
                    return
                }
                self.noteNetworkFailure("This Mac did not answer: \(secondary.detail)")
                if self.loadedLocalFile {
                    self.log("keeping the local shack page; network probes failed")
                    return
                }
                self.startLocalServerThenPoll(token: token)
            }
        }
    }

    /// A failure only covers the page when we have nothing else on screen.
    private func noteNetworkFailure(_ line: String) {
        log(line)
        if !loadedLocalFile {
            showStatus(line)
        }
    }

    private func publishedSiteCandidates() -> [URL] {
        var urls: [URL] = []
        let bundleDir = Bundle(for: GreylineHubView.self).bundleURL.deletingLastPathComponent()
        urls.append(bundleDir.appendingPathComponent("GreylineHub-site", isDirectory: true))
        for home in realHomeDirectories() {
            urls.append(home.appendingPathComponent("Library/Screen Savers/GreylineHub-site", isDirectory: true))
        }
        // Only useful if Python was given Full Disk Access and wrote the container.
        let container = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        urls.append(container.appendingPathComponent("Library/Application Support/GreylineHub/site", isDirectory: true))
        return urls
    }

    /// Homes that still point at /Users/<name> inside the screen-saver sandbox.
    /// NSHomeDirectory() is the container, which the server is not allowed to fill.
    private func realHomeDirectories() -> [URL] {
        var urls: [URL] = []
        if let pwd = getpwuid(getuid()), let dir = pwd.pointee.pw_dir {
            urls.append(URL(fileURLWithPath: String(cString: dir), isDirectory: true))
        }
        urls.append(FileManager.default.homeDirectoryForCurrentUser)
        if let env = getenv("HOME") {
            urls.append(URL(fileURLWithPath: String(cString: env), isDirectory: true))
        }
        return urls
    }

    private func findPublishedSite() -> URL? {
        var seen = Set<String>()
        for url in publishedSiteCandidates() {
            let path = url.standardizedFileURL.path
            if !seen.insert(path).inserted { continue }
            let exists = FileManager.default.fileExists(atPath: url.appendingPathComponent("index.html").path)
            log("local site \(path) index=\(exists)")
            if exists { return url }
        }
        return nil
    }

    private func loadLocalSite(_ root: URL) {
        PageHost.shared.handler.root = root
        let frame = webViewTargetFrame()
        if bounds.width < 2 || bounds.height < 2 {
            setFrameSize(frame.size)
        }
        let web = ensureWebView(frame: frame)
        guard let url = URL(string: "greyline://local/index.html") else { return }
        log("load local shack page \(root.path)")
        showStatus("Loading the local shack page. Network is not used.")
        showStatus(root.path)
        pageIsLoading = true
        loadedLocalFile = true
        web.load(URLRequest(url: url))
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
        if let site = findPublishedSite() {
            loadLocalSite(site)
            return
        }
        if attemptsLeft <= 0 {
            showStatus("Failed: network is blocked and no local shack page was published.")
            showStatus("Restart Greyline Hub on this Mac. Pass the directory you cloned, not a fixed home path.")
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
        if let existing = PageHost.shared.webView {
            webView = existing
            log("dedupe: reusing the existing web view")
            return existing
        }
        if PageHost.shared.creating, let existing = PageHost.shared.webView {
            webView = existing
            log("dedupe: web view creation already finished")
            return existing
        }
        PageHost.shared.creating = true
        defer { PageHost.shared.creating = false }
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
        configuration.setURLSchemeHandler(PageHost.shared.handler, forURLScheme: "greyline")
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
        PageHost.shared.webView = web
        log("created the single web view, clients=\(PageHost.shared.clients.count)")
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
        log("DISAPPEAR: WebContent process terminated heldSnapshot=\(lastGoodImage != nil)")
        guard lastGoodImage == nil, reloadCount < 1 else {
            log("not reloading; the held snapshot stays on screen")
            return
        }
        reloadCount += 1
        log("reloading once because no snapshot has been captured yet")
        pageIsLoading = true
        webView.reload()
    }

    private func noteSnapshot(_ image: NSImage?, error: Error?) {
        let score = image.map(contentScore) ?? 0
        if let error {
            log("DISAPPEAR: snapshot error \(error.localizedDescription) held=\(lastGoodImage != nil)")
        }
        guard let image, score >= 8 else {
            blankSnapshots += 1
            log("DISAPPEAR: snapshot blank score=\(score) streak=\(blankSnapshots) held=\(lastGoodImage != nil) webHidden=\(webView?.isHidden ?? true)")
            if lastGoodImage == nil, blankSnapshots >= 3 {
                showStatus("The page has not produced a drawable frame.")
            } else if lastGoodImage != nil {
                showHeldFrame()
            }
            return
        }
        let first = lastGoodImage == nil
        let recovered = blankSnapshots > 0
        blankSnapshots = 0
        lastGoodImage = image
        PageHost.shared.image = image
        sawContent = true
        if first || recovered {
            log("snapshot held \(Int(image.size.width))x\(Int(image.size.height)) score=\(score)")
        }
        showHeldFrame()
        hideStatus()
        NotificationCenter.default.post(name: .greylineFrame, object: nil)
    }

    private func showHeldFrame() {
        guard let image = lastGoodImage, snapshotView != nil else { return }
        snapshotView.image = image
        snapshotView.isHidden = false
        if let webView {
            addSubview(webView)
        }
        addSubview(snapshotView)
        snapshotView.needsDisplay = true
        needsDisplay = true
        displayIfNeeded()
    }

    private func contentScore(_ image: NSImage) -> Int {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else {
            return 0
        }
        let width = rep.pixelsWide
        let height = rep.pixelsHigh
        if width < 2 || height < 2 { return 0 }
        var bright = 0
        let stepX = max(1, width / 32)
        let stepY = max(1, height / 18)
        var y = 0
        while y < height {
            var x = 0
            while x < width {
                if let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) {
                    if color.redComponent + color.greenComponent + color.blueComponent > 0.28 {
                        bright += 1
                    }
                }
                x += stepX
            }
            y += stepY
        }
        return bright
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

    private func isMapURL(_ urlString: String) -> Bool {
        let path = URL(string: urlString)?.path ?? urlString
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmed == "map" || trimmed.hasSuffix("/map")
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

        let webkit = NSButton(checkboxWithTitle: "Use WebKit. Leave this off — that view goes blank on macOS 26 and 27.", target: nil, action: nil)
        webkit.frame = NSRect(x: 20, y: 48, width: 520, height: 22)
        content.addSubview(webkit)
        webkitCheckbox = webkit

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
        next.renderer = webkitCheckbox?.state == .on ? "webkit" : "native"
        saveConfig(next)
        config = next
        useNative = next.renderer != "webkit"
        endSheet()
        if useNative {
            webView?.removeFromSuperview()
            webView = nil
            wantsLayer = false
            statusLabel?.isHidden = true
            snapshotView?.isHidden = true
            nativeBoard.configure(mapOnly: isMapURL(next.primaryURL), version: bundleVersion())
            nativeBoard.reload(force: true)
            needsDisplay = true
        } else {
            if statusLabel == nil {
                configureLayer()
                installStatusLabel()
            }
            resolveAndLoad()
        }
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
