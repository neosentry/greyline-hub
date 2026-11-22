import Cocoa
import Darwin
import ScreenSaver
import WebKit

/// Full-screen Greyline Hub page.
///
/// The view does not draw the dashboard itself. It opens one page URL:
///
/// 1. Probe the primary URL (the home server) with a short timeout.
/// 2. Probe the secondary URL (usually localhost).
/// 3. If that is down and a local server is configured, start
///    `python3 -m greyline_hub` in the repo directory and poll again.
///
/// Which panels appear is decided by the page in the server config, not here.
/// See clients/README.md for the contract a Windows or Linux port should follow.
///
/// On macOS Sonoma and later, screen savers run in a sandbox that may refuse
/// to launch Python or to read an arbitrary directory. When that happens the
/// view shows the error instead of a blank screen. The reliable fix is the
/// LaunchAgent installed by install-local-server.sh, which keeps localhost up
/// before the saver starts.

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
final class GreylineHubView: ScreenSaverView, WKNavigationDelegate {
    private var webView: WKWebView?
    private var config = ClientConfig.fallback
    private var sheet: NSWindow?
    private var primaryField: NSTextField?
    private var secondaryField: NSTextField?
    private var directoryField: NSTextField?
    private var portField: NSTextField?
    private var launchCheckbox: NSButton?
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        animationTimeInterval = 60
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder decoder: NSCoder) {
        super.init(coder: decoder)
        animationTimeInterval = 60
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    override func startAnimation() {
        super.startAnimation()
        if webView == nil {
            installWebView()
        }
        config = loadConfig()
        resolveAndLoad()
    }

    override func stopAnimation() {
        super.stopAnimation()
    }

    override func draw(_ rect: NSRect) {
        NSColor.black.setFill()
        rect.fill()
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        webView?.frame = bounds
    }

    override var hasConfigureSheet: Bool { true }

    override var configureSheet: NSWindow? {
        if sheet == nil {
            sheet = buildSheet()
        }
        let current = loadConfig()
        primaryField?.stringValue = current.primaryURL
        secondaryField?.stringValue = current.secondaryURL
        directoryField?.stringValue = current.workingDirectory
        portField?.stringValue = String(current.port)
        launchCheckbox?.state = current.localServerEnabled ? .on : .off
        return sheet
    }

    private func installWebView() {
        let web = WKWebView(frame: bounds)
        web.autoresizingMask = [.width, .height]
        web.navigationDelegate = self
        if #available(macOS 12.0, *) {
            web.underPageBackgroundColor = .black
        }
        addSubview(web)
        webView = web
    }

    private func resolveAndLoad() {
        let timeout = max(0.4, config.connectTimeoutSec)
        probe(config.primaryURL, timeout: timeout) { [weak self] primaryUp in
            guard let self = self else { return }
            if primaryUp {
                self.loadPage(self.config.primaryURL)
                return
            }
            self.probe(self.config.secondaryURL, timeout: timeout) { secondaryUp in
                if secondaryUp {
                    self.loadPage(self.config.secondaryURL)
                    return
                }
                self.startLocalServerThenPoll()
            }
        }
    }

    private func startLocalServerThenPoll() {
        guard config.localServerEnabled else {
            showFailure(started: false, detail: "The local server is turned off in the screensaver settings.")
            return
        }
        let directory = (config.workingDirectory as NSString).expandingTildeInPath
        guard !directory.isEmpty, FileManager.default.fileExists(atPath: directory) else {
            showFailure(
                started: false,
                detail: "Set the Greyline Hub folder in the screensaver options, or install the LaunchAgent so localhost is already running."
            )
            return
        }
        let started = launchServer(in: directory)
        pollSecondary(attemptsLeft: Int(max(4, config.startTimeoutSec / 0.4)), started: started)
    }

    private func pollSecondary(attemptsLeft: Int, started: Bool) {
        if attemptsLeft <= 0 {
            showFailure(
                started: started,
                detail: started
                    ? "Python was started but \(config.secondaryURL) did not answer."
                    : "Python could not be started from the screensaver. This is common on macOS Sonoma and later. Install the LaunchAgent instead."
            )
            return
        }
        probe(config.secondaryURL, timeout: 0.8) { [weak self] up in
            guard let self = self else { return }
            if up {
                self.loadPage(self.config.secondaryURL)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) {
                self.pollSecondary(attemptsLeft: attemptsLeft - 1, started: started)
            }
        }
    }

    /// Returns true when this view spawned a process. A false return can still
    /// be fine: another display may already be starting the same server.
    private func launchServer(in directory: String) -> Bool {
        let support = configDirectory()
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let lockURL = support.appendingPathComponent("server.lock")
        FileManager.default.createFile(atPath: lockURL.path, contents: nil)
        let fd = open(lockURL.path, O_RDWR)
        if fd < 0 {
            return spawnPython(in: directory)
        }
        defer { close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            NSLog("Greyline Hub: another saver is starting the local server")
            return false
        }
        defer { flock(fd, LOCK_UN) }
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
        let logURL = URL(fileURLWithPath: "/tmp/greyline-hub-saver.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            process.standardOutput = handle
            process.standardError = handle
        }
        do {
            try process.run()
            NSLog("Greyline Hub started %@ in %@", python, directory)
            return true
        } catch {
            NSLog("Greyline Hub could not start Python: %@", error.localizedDescription)
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

    private func probe(_ urlString: String, timeout: TimeInterval, done: @escaping (Bool) -> Void) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme, scheme == "http" || scheme == "https" else {
            done(false)
            return
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.timeoutInterval = timeout
        let task = session.dataTask(with: request) { _, response, error in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let ok = error == nil && (200..<400).contains(code)
            DispatchQueue.main.async {
                done(ok)
            }
        }
        task.resume()
    }

    private func loadPage(_ urlString: String) {
        guard let url = URL(string: urlString) else {
            showFailure(started: false, detail: "The dashboard URL is not valid.")
            return
        }
        NSLog("Greyline Hub showing %@", urlString)
        webView?.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showFailure(started: false, detail: error.localizedDescription)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showFailure(started: false, detail: error.localizedDescription)
    }

    private func showFailure(started: Bool, detail: String) {
        let primary = escape(config.primaryURL)
        let secondary = escape(config.secondaryURL)
        let extra = escape(detail)
        let html = """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"><style>
        body { margin: 0; height: 100vh; display: flex; align-items: center; justify-content: center;
               background: #080a0d; color: #e6edf3; font: 18px -apple-system, sans-serif; }
        main { max-width: 640px; padding: 32px; }
        h1 { font-weight: 560; letter-spacing: 0.14em; font-size: 14px; color: #e4b15a; }
        p { color: #8b9bab; line-height: 1.45; }
        code { color: #79d0c4; }
        </style></head>
        <body><main>
        <h1>GREYLINE HUB</h1>
        <p>The dashboard did not answer.</p>
        <p>Primary <code>\(primary)</code><br>Secondary <code>\(secondary)</code></p>
        <p>\(extra)</p>
        <p>On the home machine, run the server on the port you chose, or publish the pages into the web server you already use. On this Mac, install the LaunchAgent so localhost stays up while you are away.</p>
        </main></body></html>
        """
        _ = started
        webView?.loadHTMLString(html, baseURL: nil)
    }

    private func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
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
        guard let data = try? Data(contentsOf: url) else {
            return .fallback
        }
        let decoder = JSONDecoder()
        return (try? decoder.decode(ClientConfig.self, from: data)) ?? .fallback
    }

    private func saveConfig(_ value: ClientConfig) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        let directory = configDirectory()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: configURL())
        NSLog("Greyline Hub wrote %@", configURL().path)
    }

    private func buildSheet() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 280),
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

        label("Primary URL (home server page)", NSRect(x: 20, y: 232, width: 520, height: 18))
        primaryField = input(NSRect(x: 20, y: 206, width: 520, height: 24))
        label("Secondary URL (this Mac, if the home server is unreachable)", NSRect(x: 20, y: 178, width: 520, height: 18))
        secondaryField = input(NSRect(x: 20, y: 152, width: 520, height: 24))
        label("Greyline Hub folder, used only if the secondary URL is down", NSRect(x: 20, y: 124, width: 400, height: 18))
        directoryField = input(NSRect(x: 20, y: 98, width: 420, height: 24))
        label("Port", NSRect(x: 450, y: 124, width: 80, height: 18))
        portField = input(NSRect(x: 450, y: 98, width: 90, height: 24))

        let checkbox = NSButton(checkboxWithTitle: "Start the local Python server when localhost is down", target: nil, action: nil)
        checkbox.frame = NSRect(x: 20, y: 62, width: 420, height: 22)
        content.addSubview(checkbox)
        launchCheckbox = checkbox

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelSheet))
        cancel.frame = NSRect(x: 350, y: 16, width: 90, height: 28)
        cancel.bezelStyle = .rounded
        content.addSubview(cancel)
        let save = NSButton(title: "Save", target: self, action: #selector(saveSheet))
        save.frame = NSRect(x: 448, y: 16, width: 90, height: 28)
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"
        content.addSubview(save)
        return window
    }

    @objc private func cancelSheet() {
        endSheet()
    }

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
        guard let sheet = sheet else { return }
        if let parent = sheet.sheetParent {
            parent.endSheet(sheet)
        } else {
            sheet.orderOut(nil)
        }
    }
}
