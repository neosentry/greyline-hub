import Cocoa

/// Menu-bar controller for the local Greyline Hub server.
/// Station settings live at http://127.0.0.1:<port>/config/, not in this app.

private let label = "com.greylinehub.server"

final class MenuApp: NSObject, NSApplicationDelegate {
    private let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let stateItem = NSMenuItem(title: "Checking the server…", action: nil, keyEquivalent: "")
    private var timer: Timer?
    private var port = 8754

    func applicationDidFinishLaunching(_ notification: Notification) {
        status.button?.title = "GL"
        status.button?.toolTip = "Greyline Hub"
        let menu = NSMenu()
        stateItem.isEnabled = false
        menu.addItem(stateItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(item("Open Configuration…", #selector(openConfig)))
        menu.addItem(item("Start Server", #selector(startServer)))
        menu.addItem(item("Stop Server", #selector(stopServer)))
        menu.addItem(item("Restart Server", #selector(restartServer)))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(item("Open Log", #selector(openLog)))
        menu.addItem(item("Quit", #selector(quit)))
        status.menu = menu
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        refresh()
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
        entry.target = self
        return entry
    }

    @objc private func refresh() {
        port = configuredPort()
        guard let url = URL(string: "http://127.0.0.1:\(port)/api/health") else { return }
        var request = URLRequest(url: url, timeoutInterval: 1.2)
        request.httpMethod = "GET"
        URLSession.shared.dataTask(with: request) { [weak self] _, response, _ in
            let ok = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
            DispatchQueue.main.async {
                self?.show(running: ok)
            }
        }.resume()
    }

    private func show(running: Bool) {
        if running {
            stateItem.title = "Server running on port \(port)"
            status.button?.title = "GL"
        } else if agentPlist() == nil {
            stateItem.title = "LaunchAgent is not installed"
            status.button?.title = "GL ?"
        } else {
            stateItem.title = "Server is not responding on port \(port)"
            status.button?.title = "GL ·"
        }
    }

    @objc private func openConfig() {
        guard let url = URL(string: "http://127.0.0.1:\(configuredPort())/config/") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func openLog() {
        let url = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/GreylineHub.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            note("No log yet at \(url.path)")
            return
        }
        NSWorkspace.shared.open(url)
    }

    @objc private func startServer() {
        guard let plist = agentPlist() else {
            note("Install the server first with clients/macos/install-local-server.sh")
            return
        }
        let domain = "gui/\(getuid())"
        launchctl(["bootout", "\(domain)/\(label)"])
        let code = launchctl(["bootstrap", domain, plist])
        launchctl(["enable", "\(domain)/\(label)"])
        launchctl(["kickstart", "-k", "\(domain)/\(label)"])
        if code != 0 {
            note("launchctl bootstrap returned \(code). See ~/Library/Logs/GreylineHub.log")
        }
        refresh()
    }

    @objc private func stopServer() {
        launchctl(["bootout", "gui/\(getuid())/\(label)"])
        refresh()
    }

    @objc private func restartServer() {
        let target = "gui/\(getuid())/\(label)"
        if launchctl(["kickstart", "-k", target]) != 0 {
            startServer()
            return
        }
        refresh()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func configuredPort() -> Int {
        guard let directory = workingDirectory() else { return 8754 }
        let url = URL(fileURLWithPath: directory).appendingPathComponent("config.json")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return 8754 }
        guard let match = text.range(of: #""port"\s*:\s*[0-9]+"#, options: .regularExpression) else { return 8754 }
        let digits = String(text[match].filter(\.isNumber))
        guard let value = Int(digits), (1...65535).contains(value) else { return 8754 }
        return value
    }

    private func workingDirectory() -> String? {
        guard let plist = agentPlist(),
              let data = try? Data(contentsOf: URL(fileURLWithPath: plist)),
              let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        else { return nil }
        let directory = object["WorkingDirectory"] as? String ?? ""
        return directory.isEmpty ? nil : directory
    }

    private func agentPlist() -> String? {
        let path = NSHomeDirectory() + "/Library/LaunchAgents/\(label).plist"
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    @discardableResult
    private func launchctl(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return 1
        }
    }

    private func note(_ text: String) {
        let alert = NSAlert()
        alert.messageText = "Greyline Hub"
        alert.informativeText = text
        alert.runModal()
    }
}

let app = NSApplication.shared
let delegate = MenuApp()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
