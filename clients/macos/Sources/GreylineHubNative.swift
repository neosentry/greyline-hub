import Cocoa
import Darwin

/// The full-screen dashboard, drawn by ScreenSaverView itself.
///
/// legacyScreenSaver hides WKWebView layer trees (hideContentUntilPendingUpdate,
/// then markAllLayersVolatile). This painter never creates a web view. It reads
/// the published status file and paints the map, greyline, clocks, space
/// weather, bands, and spots with Core Graphics.

final class NativeDashboard {
    var version = "0.1.8 (9)"
    private var mapOnly = false
    private var preset = "shack"
    private var data = DashboardData.fallback
    private var land: LandMap?
    private var siteNote = "Looking for ~/Library/Screen Savers/GreylineHub-site"
    private var loadedStatus = false
    private var statusStamp: Date?
    private var layoutStamp: Date?
    private var landStamp: Date?
    private var lastReload = Date.distantPast
    private var loggedDraw = false
    private var loggedAnimate = false
    private var shadeKey = ""
    private var dayEdge: [Double?] = []
    private var twiEdge: [Double?] = []
    private let started = Date()

    func configure(mapOnly: Bool, version: String) {
        self.mapOnly = mapOnly
        if !version.isEmpty { self.version = version }
    }

    func reload(force: Bool) {
        if !loggedAnimate {
            loggedAnimate = true
            SaverLog.write("native reload")
        }
        let elapsed = Date().timeIntervalSince(lastReload)
        if !force && elapsed < 15 { return }
        lastReload = Date()
        guard let root = findSite() else {
            siteNote = "No GreylineHub-site next to the saver. Clocks and greyline still draw."
            if force {
                SaverLog.write("native: published site not found")
            }
            return
        }
        siteNote = root.lastPathComponent
        loadLand(root)
        loadStatus(root)
    }

    func draw(in bounds: NSRect) {
        if lastReload == .distantPast {
            reload(force: true)
        }
        guard let context = NSGraphicsContext.current else { return }
        if !loggedDraw {
            loggedDraw = true
            SaverLog.write("native draw \(Int(bounds.width))x\(Int(bounds.height)) status=\(loadedStatus) land=\(land != nil) \(siteNote)")
        }
        context.saveGraphicsState()
        Palette.bg.setFill()
        bounds.fill()
        let drift = burnOffset()
        let canvas = bounds.insetBy(dx: 16 + abs(drift.x), dy: 12 + abs(drift.y))
        let shifted = canvas.offsetBy(dx: drift.x, dy: drift.y)
        if shifted.width < 80 || shifted.height < 60 {
            drawTiny(bounds)
            context.restoreGraphicsState()
            return
        }
        if shifted.height < 260 || shifted.width < 520 {
            drawCompact(shifted)
        } else {
            drawFull(shifted)
        }
        context.restoreGraphicsState()
    }

    // MARK: - Files

    private func findSite() -> URL? {
        var urls: [URL] = []
        let bundleDir = Bundle(for: GreylineHubView.self).bundleURL.deletingLastPathComponent()
        urls.append(bundleDir.appendingPathComponent("GreylineHub-site", isDirectory: true))
        if let pwd = getpwuid(getuid()), let dir = pwd.pointee.pw_dir {
            let home = URL(fileURLWithPath: String(cString: dir), isDirectory: true)
            urls.append(home.appendingPathComponent("Library/Screen Savers/GreylineHub-site", isDirectory: true))
        }
        if let env = getenv("HOME") {
            let home = URL(fileURLWithPath: String(cString: env), isDirectory: true)
            urls.append(home.appendingPathComponent("Library/Screen Savers/GreylineHub-site", isDirectory: true))
        }
        var seen = Set<String>()
        for url in urls {
            let path = url.standardizedFileURL.path
            if !seen.insert(path).inserted { continue }
            let index = url.appendingPathComponent("index.html")
            let status = url.appendingPathComponent("data/status.json")
            if FileManager.default.fileExists(atPath: index.path) || FileManager.default.fileExists(atPath: status.path) {
                return url
            }
        }
        return nil
    }

    private func loadLand(_ root: URL) {
        let url = root.appendingPathComponent("assets/land.geojson")
        let stamp = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        if land != nil, stamp == landStamp { return }
        guard let raw = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            SaverLog.write("native: no land outline at \(url.path)")
            return
        }
        land = LandMap(json: object)
        landStamp = stamp
        SaverLog.write("native: land \(land?.polygons.count ?? 0) polygons")
    }

    private func loadStatus(_ root: URL) {
        let url = root.appendingPathComponent("data/status.json")
        let layoutURL = root.appendingPathComponent("data/layout.json")
        let stamp = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        let layoutTime = (try? layoutURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        if loadedStatus, stamp == statusStamp, layoutTime == layoutStamp { return }
        guard let raw = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            siteNote = "Waiting for \(url.path)"
            SaverLog.write("native: status unreadable \(url.path)")
            return
        }
        data = DashboardData(json: object, mapOnly: mapOnly)
        if let layoutRaw = try? Data(contentsOf: layoutURL),
           let layout = try? JSONSerialization.jsonObject(with: layoutRaw) as? [String: Any] {
            applyLayout(layout)
        }
        loadedStatus = true
        statusStamp = stamp
        layoutStamp = layoutTime
        shadeKey = ""
        let call = data.callsign
        SaverLog.write("native: status \(call) \(data.grid) spots=\(data.spots.count) bands=\(data.bands.count)")
        siteNote = "\(call) · \(url.deletingLastPathComponent().lastPathComponent)"
    }

    /// layout.json is the configuration app's view of panels, preset, and filters.
    private func applyLayout(_ layout: [String: Any]) {
        if let name = layout["preset"] as? String, !name.isEmpty {
            preset = name
        }
        if let station = layout["station"] as? [String: Any] {
            data.callsign = text(station["callsign"], fallback: data.callsign)
            data.grid = text(station["grid"], fallback: data.grid)
            data.timezone = text(station["timezone"], fallback: data.timezone)
            data.lat = number(station["lat"]) ?? data.lat
            data.lon = number(station["lon"]) ?? data.lon
        }
        if let names = layout["panels"] as? [String], !names.isEmpty {
            data.panels = Set(names)
        }
        if let rows = number(layout["dx_rows"]) {
            data.dxRows = max(1, Int(rows))
        }
        guard let filter = layout["dx_filter"] as? [String: Any] else { return }
        let bands = Set((filter["bands"] as? [String] ?? []).map { $0.lowercased() })
        let modes = Set((filter["modes"] as? [String] ?? []).map { $0.uppercased() })
        if let cap = number(filter["max_count"]) {
            data.dxRows = min(data.dxRows, max(1, Int(cap)))
        }
        data.spots = data.spots.filter { spot in
            if !bands.isEmpty && !bands.contains(spot.band.lowercased()) { return false }
            if !modes.isEmpty && !modes.contains(spot.mode.uppercased()) { return false }
            return true
        }
        data.spots = Array(data.spots.prefix(data.dxRows))
    }

    // MARK: - Layout

    private func drawFull(_ rect: NSRect) {
        let headerH: CGFloat = min(78, rect.height * 0.11)
        let footerH: CGFloat = 22
        let showDX = data.panels.contains("dx_spots")
        let dxCap: CGFloat = preset == "spots-heavy" ? 460 : (preset == "map-heavy" ? 150 : 230)
        let dxShare: CGFloat = preset == "spots-heavy" ? 0.42 : (preset == "map-heavy" ? 0.16 : 0.26)
        let dxFloor: CGFloat = preset == "map-heavy" ? 72 : 120
        let dxH: CGFloat = showDX ? min(dxCap, max(dxFloor, rect.height * dxShare)) : 0
        let header = NSRect(x: rect.minX, y: rect.maxY - headerH, width: rect.width, height: headerH)
        let footer = NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: footerH)
        let mid = NSRect(x: rect.minX, y: footer.maxY + 8, width: rect.width, height: header.minY - footer.maxY - 16)
        drawHeader(header)
        let showSide = data.panels.contains("space_weather") || data.panels.contains("bands")
        let sideW: CGFloat = showSide ? min(380, max(240, rect.width * 0.28)) : 0
        let map = NSRect(x: mid.minX, y: mid.minY + dxH + (showDX ? 8 : 0), width: mid.width - sideW - (showSide ? 10 : 0), height: mid.height - dxH - (showDX ? 8 : 0))
        drawMap(map)
        if showSide {
            let side = NSRect(x: map.maxX + 10, y: map.minY, width: sideW, height: map.height)
            drawSide(side)
        }
        if showDX {
            let dx = NSRect(x: mid.minX, y: mid.minY, width: mid.width, height: dxH)
            drawSpots(dx)
        }
        drawFooter(footer)
    }

    private func drawCompact(_ rect: NSRect) {
        let header = NSRect(x: rect.minX, y: rect.maxY - 36, width: rect.width, height: 34)
        drawHeader(header)
        let map = NSRect(x: rect.minX, y: rect.minY + 18, width: rect.width, height: header.minY - rect.minY - 22)
        drawMap(map)
        drawFooter(NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: 16))
    }

    private func drawTiny(_ rect: NSRect) {
        let title = "GREYLINE  \(version)"
        drawText(title, NSRect(x: rect.minX + 8, y: rect.midY - 8, width: rect.width - 16, height: 18), font: Palette.font(12, .semibold), color: Palette.amber)
    }

    private func drawHeader(_ rect: NSRect) {
        let brandW = min(220, rect.width * 0.22)
        let brand = NSMutableAttributedString(string: "GREYLINE ", attributes: [
            .font: Palette.font(22, .semibold),
            .foregroundColor: Palette.ink,
        ])
        brand.append(NSAttributedString(string: "HUB", attributes: [
            .font: Palette.font(22, .semibold),
            .foregroundColor: Palette.amber,
        ]))
        brand.draw(in: NSRect(x: rect.minX, y: rect.maxY - 30, width: brandW, height: 28))
        drawText(data.title, NSRect(x: rect.minX, y: rect.minY + 2, width: brandW, height: 16), font: Palette.font(12, .regular), color: Palette.dim)

        let station = NSRect(x: rect.minX + brandW, y: rect.minY, width: min(220, rect.width * 0.2), height: rect.height)
        drawText(data.callsign, NSRect(x: station.minX, y: station.maxY - 30, width: station.width, height: 28), font: Palette.font(24, .medium), color: Palette.cyan)
        let state = daylightLabel()
        drawText("\(data.grid)   \(state.name)  \(state.elev)", NSRect(x: station.minX, y: station.minY + 4, width: station.width, height: 16), font: Palette.font(12, .regular), color: state.color)

        let clockW = min(210, (rect.maxX - station.maxX - 8) / 2)
        let utc = NSRect(x: rect.maxX - clockW * 2 - 8, y: rect.minY, width: clockW, height: rect.height)
        let local = NSRect(x: rect.maxX - clockW, y: rect.minY, width: clockW, height: rect.height)
        drawClock(utc, label: "UTC", time: formatTime(Date(), zone: TimeZone(identifier: "UTC")), sub: utcSub())
        drawClock(local, label: zoneLabel(), time: formatTime(Date(), zone: TimeZone(identifier: data.timezone)), sub: localSub())
    }

    private func drawClock(_ rect: NSRect, label: String, time: String, sub: String) {
        drawText(label, NSRect(x: rect.minX, y: rect.maxY - 14, width: rect.width, height: 14), font: Palette.font(11, .medium), color: Palette.dim, align: .right)
        drawText(time, NSRect(x: rect.minX, y: rect.maxY - 42, width: rect.width, height: 28), font: Palette.mono(26), color: Palette.ink, align: .right)
        drawText(sub, NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: 14), font: Palette.font(11, .regular), color: Palette.dim, align: .right)
    }

    private func drawSide(_ rect: NSRect) {
        var cursor = rect.maxY
        if data.panels.contains("space_weather") {
            let h = min(rect.height * 0.46, 250)
            drawWeather(NSRect(x: rect.minX, y: cursor - h, width: rect.width, height: h))
            cursor -= h + 8
        }
        if data.panels.contains("bands"), cursor - rect.minY > 40 {
            drawBands(NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: cursor - rect.minY))
        }
    }

    private func drawWeather(_ rect: NSRect) {
        panel(rect)
        let head = data.weather.empty ? "no report" : (data.weather.stale ? "stale" : "")
        drawText("SPACE WEATHER", NSRect(x: rect.minX + 10, y: rect.maxY - 22, width: rect.width - 90, height: 16), font: Palette.font(12, .semibold), color: Palette.amber)
        drawText(head, NSRect(x: rect.maxX - 80, y: rect.maxY - 22, width: 70, height: 16), font: Palette.font(11, .medium), color: Palette.fair, align: .right)
        let fields: [(String, String, NSColor)] = [
            ("SFI", data.weather.sfi, Palette.ink),
            ("SSN", data.weather.ssn, Palette.ink),
            ("Kp", data.weather.kp, kpColor(data.weather.kpValue)),
            ("A", data.weather.a, Palette.ink),
            ("X-ray", data.weather.xray, xrayColor(data.weather.xray)),
            ("Wind", data.weather.wind, Palette.ink),
            ("Bz", data.weather.bz, Palette.ink),
            ("R S G", data.weather.scales, Palette.ink),
        ]
        let cols = 4
        let rows = 2
        let grid = NSRect(x: rect.minX + 8, y: rect.minY + 22, width: rect.width - 16, height: rect.height - 48)
        let cw = grid.width / CGFloat(cols)
        let rh = grid.height / CGFloat(rows)
        for (index, field) in fields.enumerated() {
            let col = index % cols
            let row = index / cols
            let cell = NSRect(x: grid.minX + CGFloat(col) * cw, y: grid.maxY - CGFloat(row + 1) * rh, width: cw - 4, height: rh)
            drawText(field.0, NSRect(x: cell.minX, y: cell.maxY - 14, width: cell.width, height: 14), font: Palette.font(11, .medium), color: Palette.dim)
            drawText(field.1, NSRect(x: cell.minX, y: cell.minY + 2, width: cell.width, height: cell.height - 16), font: Palette.mono(min(28, rh * 0.55)), color: field.2)
        }
        drawText(data.weather.note, NSRect(x: rect.minX + 10, y: rect.minY + 4, width: rect.width - 20, height: 14), font: Palette.font(11, .regular), color: Palette.dim)
    }

    private func drawBands(_ rect: NSRect) {
        panel(rect)
        let extra = data.bandsEstimated ? "estimated" : (data.bandsStale ? "stale" : "")
        drawText("HF BANDS", NSRect(x: rect.minX + 10, y: rect.maxY - 22, width: rect.width * 0.6, height: 16), font: Palette.font(12, .semibold), color: Palette.amber)
        drawText(extra, NSRect(x: rect.minX + rect.width * 0.55, y: rect.maxY - 22, width: rect.width * 0.4 - 10, height: 16), font: Palette.font(11, .medium), color: Palette.fair, align: .right)
        let rows = data.bands.isEmpty ? [BandRow(name: "—", day: "–", night: "–")] : data.bands
        let top = rect.maxY - 28
        let rowH = min(18, max(12, (top - rect.minY - 8) / CGFloat(rows.count + 1)))
        let nameW = rect.width * 0.34
        drawText("Band", NSRect(x: rect.minX + 10, y: top - rowH, width: nameW, height: rowH), font: Palette.font(11, .medium), color: Palette.dim)
        drawText("Day", NSRect(x: rect.minX + 10 + nameW, y: top - rowH, width: (rect.width - nameW - 20) / 2, height: rowH), font: Palette.font(11, .medium), color: Palette.dim)
        drawText("Night", NSRect(x: rect.minX + 10 + nameW + (rect.width - nameW - 20) / 2, y: top - rowH, width: (rect.width - nameW - 20) / 2, height: rowH), font: Palette.font(11, .medium), color: Palette.dim)
        for (index, row) in rows.enumerated() {
            let y = top - rowH * CGFloat(index + 2)
            if y < rect.minY { break }
            drawText(row.name, NSRect(x: rect.minX + 10, y: y, width: nameW, height: rowH), font: Palette.font(12, .regular), color: Palette.ink)
            drawText(row.day, NSRect(x: rect.minX + 10 + nameW, y: y, width: (rect.width - nameW - 20) / 2, height: rowH), font: Palette.font(12, .medium), color: condColor(row.day))
            drawText(row.night, NSRect(x: rect.minX + 10 + nameW + (rect.width - nameW - 20) / 2, y: y, width: (rect.width - nameW - 20) / 2, height: rowH), font: Palette.font(12, .medium), color: condColor(row.night))
        }
    }

    private func drawSpots(_ rect: NSRect) {
        panel(rect)
        let head = data.spots.isEmpty ? "quiet" : data.spotsSource
        drawText("DX SPOTS", NSRect(x: rect.minX + 10, y: rect.maxY - 20, width: 120, height: 16), font: Palette.font(12, .semibold), color: Palette.amber)
        drawText(head, NSRect(x: rect.minX + 130, y: rect.maxY - 20, width: rect.width - 140, height: 16), font: Palette.font(11, .regular), color: Palette.dim)
        let columns: [(String, CGFloat)] = [
            ("UTC", 0.08), ("MHz", 0.10), ("Band", 0.08), ("DX", 0.16),
            ("Mode", 0.08), ("Spotter", 0.14), ("Where", 0.16), ("Note", 0.20),
        ]
        var x = rect.minX + 10
        let usable = rect.width - 20
        let yHead = rect.maxY - 38
        for column in columns {
            let w = usable * column.1
            drawText(column.0, NSRect(x: x, y: yHead, width: w - 4, height: 14), font: Palette.font(11, .medium), color: Palette.dim)
            x += w
        }
        let items = Array(data.spots.prefix(data.dxRows))
        let rowH: CGFloat = 16
        if items.isEmpty {
            drawText("No fresh spots.", NSRect(x: rect.minX + 10, y: yHead - 22, width: usable, height: 16), font: Palette.font(12, .regular), color: Palette.dim)
            return
        }
        for (index, spot) in items.enumerated() {
            let y = yHead - rowH * CGFloat(index + 1) - 4
            if y < rect.minY { break }
            let values = [spot.time, spot.mhz, spot.band, spot.dx, spot.mode, spot.spotter, spot.country, spot.note]
            var colX = rect.minX + 10
            for (col, value) in values.enumerated() {
                let w = usable * columns[col].1
                let color = col == 3 ? Palette.amber2 : Palette.ink
                drawText(value, NSRect(x: colX, y: y, width: w - 4, height: rowH), font: Palette.font(12, .regular), color: color)
                colX += w
            }
        }
    }

    private func drawFooter(_ rect: NSRect) {
        let left = "Greyline Hub \(version)  ·  native"
        drawText(left, NSRect(x: rect.minX, y: rect.minY, width: rect.width * 0.55, height: rect.height), font: Palette.font(11, .regular), color: Palette.dim)
        let right = loadedStatus ? data.feedLine : siteNote
        drawText(right, NSRect(x: rect.minX + rect.width * 0.4, y: rect.minY, width: rect.width * 0.6, height: rect.height), font: Palette.font(11, .regular), color: Palette.dim, align: .right)
    }

    private func panel(_ rect: NSRect) {
        Palette.panel.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
    }

    // MARK: - Map

    private func drawMap(_ rect: NSRect) {
        guard rect.width > 4, rect.height > 4 else { return }
        Palette.ocean.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
        NSGraphicsContext.current?.saveGraphicsState()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).addClip()
        if let land {
            Palette.land.setFill()
            let path = NSBezierPath()
            path.windingRule = .evenOdd
            for polygon in land.polygons {
                for ring in polygon {
                    guard let first = ring.first else { continue }
                    path.move(to: project(first.0, first.1, rect))
                    for point in ring.dropFirst() {
                        path.line(to: project(point.0, point.1, rect))
                    }
                    path.close()
                }
            }
            path.fill()
            Palette.coast.setStroke()
            path.lineWidth = 0.6
            path.stroke()
        }
        if data.showGraticule { drawGraticule(rect) }
        if data.showGreyline { shadeNight(rect) }
        if data.showSun { drawSun(rect) }
        if data.showSpotsOnMap { drawSpotMarks(rect) }
        if data.showHome { drawHome(rect) }
        NSGraphicsContext.current?.restoreGraphicsState()
    }

    private func drawGraticule(_ rect: NSRect) {
        Palette.grid.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1
        var lon = -150.0
        while lon < 180 {
            let x = project(lon, 0, rect).x
            path.move(to: NSPoint(x: x, y: rect.minY))
            path.line(to: NSPoint(x: x, y: rect.maxY))
            lon += 30
        }
        var lat = -60.0
        while lat <= 60 {
            let y = project(0, lat, rect).y
            path.move(to: NSPoint(x: rect.minX, y: y))
            path.line(to: NSPoint(x: rect.maxX, y: y))
            lat += 30
        }
        path.stroke()
    }

    private func shadeNight(_ rect: NSRect) {
        let solar = Solar.position(Date())
        let key = "\(Int(rect.width)):\(Int(solar.subLon * 10)):\(Int(solar.declination * 10))"
        let columns = max(1, Int(rect.width / 3))
        if key != shadeKey || dayEdge.count != columns {
            dayEdge = []
            twiEdge = []
            dayEdge.reserveCapacity(columns)
            for index in 0..<columns {
                let lon = (Double(index) + 0.5) / Double(columns) * 360 - 180
                dayEdge.append(Solar.crossing(decl: solar.declination, subLon: solar.subLon, lon: lon, alpha: 0))
                twiEdge.append(Solar.crossing(decl: solar.declination, subLon: solar.subLon, lon: lon, alpha: -6))
            }
            shadeKey = key
        }
        let nightSouth = solar.declination >= 0
        let columnW = rect.width / CGFloat(columns)
        Palette.night.setFill()
        for index in 0..<columns {
            let x = rect.minX + CGFloat(index) * columnW
            guard let day = dayEdge[index] else {
                let noon = Solar.elevation(lat: 0, lon: (Double(index) + 0.5) / Double(columns) * 360 - 180, decl: solar.declination, subLon: solar.subLon)
                if noon < 0 {
                    NSRect(x: x, y: rect.minY, width: columnW + 0.5, height: rect.height).fill()
                }
                continue
            }
            let y0 = project(0, day, rect).y
            if nightSouth {
                NSRect(x: x, y: rect.minY, width: columnW + 0.5, height: max(0, y0 - rect.minY)).fill()
            } else {
                NSRect(x: x, y: y0, width: columnW + 0.5, height: max(0, rect.maxY - y0)).fill()
            }
        }
        Palette.dusk.setFill()
        for index in 0..<columns {
            guard let day = dayEdge[index], let twi = twiEdge[index] else { continue }
            let y0 = project(0, day, rect).y
            let y6 = project(0, twi, rect).y
            let x = rect.minX + CGFloat(index) * columnW
            NSRect(x: x, y: min(y0, y6), width: columnW + 0.5, height: abs(y6 - y0)).fill()
        }
        let line = NSBezierPath()
        var open = false
        for index in stride(from: 0, to: columns, by: 2) {
            guard let day = dayEdge[index] else {
                open = false
                continue
            }
            let point = NSPoint(x: rect.minX + CGFloat(index) * columnW, y: project(0, day, rect).y)
            if !open {
                line.move(to: point)
                open = true
            } else {
                line.line(to: point)
            }
        }
        Palette.greylineWide.setStroke()
        line.lineWidth = 8
        line.lineCapStyle = .round
        line.stroke()
        Palette.greyline.setStroke()
        line.lineWidth = 1.6
        line.stroke()
    }

    private func drawSun(_ rect: NSRect) {
        let solar = Solar.position(Date())
        let point = project(solar.subLon, solar.subLat, rect)
        Palette.sun.setFill()
        NSBezierPath(ovalIn: NSRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10)).fill()
        Palette.sunRing.setStroke()
        let ring = NSBezierPath(ovalIn: NSRect(x: point.x - 9, y: point.y - 9, width: 18, height: 18))
        ring.lineWidth = 1
        ring.stroke()
    }

    private func drawSpotMarks(_ rect: NSRect) {
        for spot in data.spots {
            guard let lat = spot.lat, let lon = spot.lon else { continue }
            let point = project(lon, lat, rect)
            Palette.band(spot.band).setFill()
            NSBezierPath(ovalIn: NSRect(x: point.x - 2.5, y: point.y - 2.5, width: 5, height: 5)).fill()
        }
        guard data.showLabels else { return }
        var boxes: [NSRect] = []
        let font = Palette.font(12, .medium)
        for spot in data.spots.prefix(8) {
            guard let lat = spot.lat, let lon = spot.lon, !spot.dx.isEmpty else { continue }
            let point = project(lon, lat, rect)
            let width = (spot.dx as NSString).size(withAttributes: [.font: font]).width + 4
            let box = NSRect(x: point.x + 6, y: point.y + 2, width: width, height: 14)
            let blocked = boxes.contains { $0.intersects(box) }
            if blocked { continue }
            boxes.append(box)
            drawText(spot.dx, box, font: font, color: Palette.amber2)
        }
    }

    private func drawHome(_ rect: NSRect) {
        let point = project(data.lon, data.lat, rect)
        Palette.cyan.setStroke()
        let mark = NSBezierPath()
        mark.lineWidth = 1.4
        mark.appendRect(NSRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10))
        mark.move(to: NSPoint(x: point.x - 9, y: point.y))
        mark.line(to: NSPoint(x: point.x + 9, y: point.y))
        mark.move(to: NSPoint(x: point.x, y: point.y - 9))
        mark.line(to: NSPoint(x: point.x, y: point.y + 9))
        mark.stroke()
        drawText(data.callsign, NSRect(x: point.x + 12, y: point.y + 4, width: 90, height: 14), font: Palette.font(12, .semibold), color: Palette.cyan)
    }

    private func project(_ lon: Double, _ lat: Double, _ rect: NSRect) -> NSPoint {
        let x = rect.minX + CGFloat((lon + 180) / 360) * rect.width
        let y = rect.minY + CGFloat((lat + 90) / 180) * rect.height
        return NSPoint(x: x, y: y)
    }

    // MARK: - Text

    private func daylightLabel() -> (name: String, elev: String, color: NSColor) {
        let solar = Solar.position(Date())
        let elev = Solar.elevation(lat: data.lat, lon: data.lon, decl: solar.declination, subLon: solar.subLon)
        let name: String
        let color: NSColor
        if elev >= -12 && elev <= 6 {
            name = "Greyline"
            color = Palette.amber
        } else if elev > 6 {
            name = "Day"
            color = Palette.good
        } else {
            name = "Night"
            color = Palette.dim
        }
        return (name, String(format: "elev %.0f°", elev), color)
    }

    private func utcSub() -> String {
        let date = formatDate(Date(), zone: TimeZone(identifier: "UTC"))
        return [date, riseSet(data.sunriseUTC, data.sunsetUTC)].filter { !$0.isEmpty }.joined(separator: "  ")
    }

    private func localSub() -> String {
        let date = formatDate(Date(), zone: TimeZone(identifier: data.timezone))
        return [date, riseSet(data.sunriseLocal, data.sunsetLocal)].filter { !$0.isEmpty }.joined(separator: "  ")
    }

    private func riseSet(_ rise: String, _ set: String) -> String {
        var parts: [String] = []
        if !rise.isEmpty && rise != "–" { parts.append("rise \(rise)") }
        if !set.isEmpty && set != "–" { parts.append("set \(set)") }
        return parts.joined(separator: "  ")
    }

    private func zoneLabel() -> String {
        let zone = TimeZone(identifier: data.timezone) ?? .current
        let name = zone.abbreviation(for: Date()) ?? "Local"
        return name
    }

    private func formatTime(_ date: Date, zone: TimeZone?) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.timeZone = zone ?? TimeZone(identifier: "UTC")
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    private func formatDate(_ date: Date, zone: TimeZone?) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.timeZone = zone ?? TimeZone(identifier: "UTC")
        formatter.dateFormat = "EEE dd MMM"
        return formatter.string(from: date)
    }

    private func burnOffset() -> NSPoint {
        guard data.burnEnabled, data.burnPixels > 0, data.burnPeriod > 0 else { return .zero }
        let path: [(CGFloat, CGFloat)] = [
            (0, 0), (1, 0.35), (0.4, 1), (-0.8, 0.45), (-0.3, -0.7), (0.65, -0.25),
        ]
        let step = data.burnPeriod / Double(path.count)
        let index = Int(Date().timeIntervalSince(started) / step) % path.count
        let pair = path[index]
        return NSPoint(x: pair.0 * CGFloat(data.burnPixels), y: pair.1 * CGFloat(data.burnPixels))
    }

    private func drawText(_ text: String, _ rect: NSRect, font: NSFont, color: NSColor, align: NSTextAlignment = .left) {
        let style = NSMutableParagraphStyle()
        style.alignment = align
        style.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: style,
        ]
        (text as NSString).draw(in: rect, withAttributes: attrs)
    }

    private func kpColor(_ value: Double?) -> NSColor {
        guard let value else { return Palette.ink }
        if value >= 5 { return Palette.poor }
        if value >= 4 { return Palette.fair }
        return Palette.good
    }

    private func xrayColor(_ text: String) -> NSColor {
        let upper = text.uppercased()
        if upper.hasPrefix("X") || upper.hasPrefix("M") { return Palette.poor }
        if upper.hasPrefix("C") { return Palette.fair }
        return Palette.good
    }

    private func condColor(_ text: String) -> NSColor {
        let value = text.lowercased()
        if value.contains("good") || value.contains("open") { return Palette.good }
        if value.contains("fair") { return Palette.fair }
        if value.contains("poor") || value.contains("closed") { return Palette.poor }
        return Palette.dim
    }
}

private extension NSRect {
    func offsetBy(dx: CGFloat, dy: CGFloat) -> NSRect {
        NSRect(x: minX + dx, y: minY + dy, width: width, height: height)
    }
}

// MARK: - Solar

private enum Solar {
    struct Place {
        var declination: Double
        var subLat: Double
        var subLon: Double
    }

    static func position(_ date: Date) -> Place {
        let t = julianCentury(date)
        let l0 = (280.46646 + t * (36000.76983 + t * 0.0003032)).truncatingRemainder(dividingBy: 360)
        let m = (357.52911 + t * (35999.05029 - 0.0001537 * t)).truncatingRemainder(dividingBy: 360)
        let e = 0.016708634 - t * (0.000042037 + 0.0000001267 * t)
        let mr = m * .pi / 180
        let c = sin(mr) * (1.914602 - t * (0.004817 + 0.000014 * t))
            + sin(2 * mr) * (0.019993 - 0.000101 * t)
            + sin(3 * mr) * 0.000289
        let trueLong = l0 + c
        let omega = 125.04 - 1934.136 * t
        let lam = trueLong - 0.00569 - 0.00478 * sin(omega * .pi / 180)
        let eps0 = 23 + (26 + (21.448 - t * (46.815 + t * (0.00059 - t * 0.001813))) / 60) / 60
        let eps = eps0 + 0.00256 * cos(omega * .pi / 180)
        let decl = asin(sin(eps * .pi / 180) * sin(lam * .pi / 180)) * 180 / .pi
        let y = pow(tan(eps * .pi / 360), 2)
        let l0r = l0 * .pi / 180
        let eqtime = 4 * (
            y * sin(2 * l0r)
                - 2 * e * sin(mr)
                + 4 * e * y * sin(mr) * cos(2 * l0r)
                - 0.5 * y * y * sin(4 * l0r)
                - 1.25 * e * e * sin(2 * mr)
        ) * 180 / .pi
        let hours = utcHours(date)
        let sub = wrap180(-15 * (hours - 12) - eqtime / 4)
        return Place(declination: decl, subLat: decl, subLon: sub)
    }

    static func elevation(lat: Double, lon: Double, decl: Double, subLon: Double) -> Double {
        let ha = (lon - subLon) * .pi / 180
        let dec = decl * .pi / 180
        let la = lat * .pi / 180
        var sine = sin(la) * sin(dec) + cos(la) * cos(dec) * cos(ha)
        sine = min(1, max(-1, sine))
        return asin(sine) * 180 / .pi
    }

    static func crossing(decl: Double, subLon: Double, lon: Double, alpha: Double) -> Double? {
        var previous: Double?
        var previousLat: Double?
        var lat = -90.0
        while lat <= 90 {
            let value = elevation(lat: lat, lon: lon, decl: decl, subLon: subLon) - alpha
            if let previous, let previousLat, previous * value < 0 {
                let frac = abs(previous) / (abs(previous) + abs(value))
                return previousLat + frac * (lat - previousLat)
            }
            previous = value
            previousLat = lat
            lat += 2
        }
        return nil
    }

    private static func julianCentury(_ date: Date) -> Double {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: date)
        var year = parts.year ?? 2000
        var month = parts.month ?? 1
        if month <= 2 {
            year -= 1
            month += 12
        }
        let a = year / 100
        let b = 2 - a + a / 4
        let day = Double(parts.day ?? 1)
            + Double(parts.hour ?? 0) / 24
            + Double(parts.minute ?? 0) / 1440
            + Double(parts.second ?? 0) / 86400
            + Double(parts.nanosecond ?? 0) / 86400 / 1e9
        let jd = floor(365.25 * Double(year + 4716)) + floor(30.6001 * Double(month + 1)) + day + Double(b) - 1524.5
        return (jd - 2451545) / 36525
    }

    private static func utcHours(_ date: Date) -> Double {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
        return Double(parts.hour ?? 0) + Double(parts.minute ?? 0) / 60 + Double(parts.second ?? 0) / 3600
    }

    private static func wrap180(_ degrees: Double) -> Double {
        var value = degrees.truncatingRemainder(dividingBy: 360)
        if value > 180 { value -= 360 }
        if value < -180 { value += 360 }
        return value
    }
}

// MARK: - Model

private struct BandRow {
    var name: String
    var day: String
    var night: String
}

private struct SpotMark {
    var time: String
    var mhz: String
    var band: String
    var dx: String
    var mode: String
    var spotter: String
    var country: String
    var note: String
    var lat: Double?
    var lon: Double?
}

private struct WeatherBox {
    init() {}
    var sfi = "–"
    var ssn = "–"
    var kp = "–"
    var kpValue: Double?
    var a = "–"
    var xray = "–"
    var wind = "–"
    var bz = "–"
    var scales = "–"
    var note = ""
    var stale = false
    var empty = true
}

private struct DashboardData {
    var title = "Shack"
    var callsign = "K0JNM"
    var grid = "EL87uu"
    var timezone = "America/New_York"
    var lat = 27.854167
    var lon = -82.291667
    var sunriseUTC = ""
    var sunsetUTC = ""
    var sunriseLocal = ""
    var sunsetLocal = ""
    var weather = WeatherBox()
    var bands: [BandRow] = []
    var bandsEstimated = false
    var bandsStale = false
    var spots: [SpotMark] = []
    var spotsSource = ""
    var panels: Set<String> = ["clock", "map", "space_weather", "bands", "dx_spots"]
    var dxRows = 10
    var showSpotsOnMap = true
    var showLabels = true
    var showGreyline = true
    var showHome = true
    var showSun = true
    var showGraticule = true
    var burnEnabled = true
    var burnPeriod = 180.0
    var burnPixels = 8.0
    var feedLine = ""

    static let fallback = DashboardData()

    init() {}

    init(json: [String: Any], mapOnly: Bool) {
        self.init()
        if let station = json["station"] as? [String: Any] {
            callsign = text(station["callsign"], fallback: callsign)
            grid = text(station["grid"], fallback: grid)
            timezone = text(station["timezone"], fallback: timezone)
            lat = number(station["lat"]) ?? lat
            lon = number(station["lon"]) ?? lon
            sunriseUTC = text(station["sunrise_utc"], fallback: "")
            sunsetUTC = text(station["sunset_utc"], fallback: "")
            sunriseLocal = text(station["sunrise_local"], fallback: "")
            sunsetLocal = text(station["sunset_local"], fallback: "")
        }
        weather = WeatherBox(json: json["space_weather"] as? [String: Any])
        if let bandsBox = json["bands"] as? [String: Any] {
            bandsEstimated = bandsBox["estimated"] as? Bool ?? false
            bandsStale = bandsBox["stale"] as? Bool ?? false
            if let rows = bandsBox["rows"] as? [[String: Any]] {
                bands = rows.map {
                    BandRow(name: text($0["name"], fallback: ""), day: text($0["day"], fallback: "–"), night: text($0["night"], fallback: "–"))
                }
            }
        }
        if let spotsBox = json["spots"] as? [String: Any] {
            spotsSource = text(spotsBox["source"], fallback: "")
            if let items = spotsBox["items"] as? [[String: Any]] {
                spots = items.map(SpotMark.init(json:))
            }
        }
        let pages = json["pages"] as? [[String: Any]] ?? []
        let page = pages.first { page in
            let id = page["id"] as? String ?? ""
            let slug = page["slug"] as? String ?? ""
            return mapOnly ? (id == "map" || slug == "map") : (id == "main" || slug.isEmpty)
        } ?? pages.first
        if let page {
            title = text(page["title"], fallback: mapOnly ? "Map" : "Shack")
            if let names = page["panels"] as? [String] {
                panels = Set(names)
            }
            if let rows = number(page["dx_rows"]) {
                dxRows = max(1, Int(rows))
            }
            if let map = page["map"] as? [String: Any] {
                showSpotsOnMap = map["spots"] as? Bool ?? true
                showLabels = map["labels"] as? Bool ?? true
                showGreyline = map["greyline"] as? Bool ?? true
                showHome = map["home"] as? Bool ?? true
                showSun = map["sun"] as? Bool ?? true
                showGraticule = map["graticule"] as? Bool ?? true
            }
            if let burn = page["burn_in"] as? [String: Any] {
                burnEnabled = burn["enabled"] as? Bool ?? true
                burnPeriod = number(burn["period_sec"]) ?? burnPeriod
                burnPixels = number(burn["pixels"]) ?? burnPixels
            }
        } else if mapOnly {
            panels = ["clock", "map", "dx_spots"]
            title = "Map"
        }
        feedLine = feedSummary(json["feeds"] as? [String: Any])
    }
}

private extension WeatherBox {
    init(json: [String: Any]?) {
        self.init()
        guard let json else { return }
        empty = json["empty"] as? Bool ?? false
        stale = json["stale"] as? Bool ?? false
        sfi = field(json["sfi"], digits: 0)
        ssn = field(json["ssn"], digits: 0)
        kp = field(json["kp"], digits: 2)
        kpValue = fieldNumber(json["kp"])
        a = field(json["a"], digits: 0)
        xray = field(json["xray"], digits: nil)
        wind = field(json["solar_wind"], digits: 0)
        bz = field(json["bz"], digits: 1)
        let scales = json["scales"] as? [String: Any] ?? [:]
        let r = short(scales["R"])
        let s = short(scales["S"])
        let g = short(scales["G"])
        self.scales = "\(r)  \(s)  \(g)"
        var notes: [String] = []
        if let geomag = json["geomag"] as? String, !geomag.isEmpty { notes.append(geomag) }
        if let noise = json["noise"] as? String, !noise.isEmpty { notes.append(noise) }
        if let muf = number(json["muf"]) { notes.append(String(format: "MUF %.0f MHz", muf)) }
        note = notes.joined(separator: " · ")
    }
}

private extension SpotMark {
    init(json: [String: Any]) {
        let rawTime = text(json["time"], fallback: "")
        if rawTime.count >= 16 {
            time = String(rawTime[rawTime.index(rawTime.startIndex, offsetBy: 11)..<rawTime.index(rawTime.startIndex, offsetBy: 16)])
        } else {
            time = rawTime.isEmpty ? "–" : rawTime
        }
        if let khz = number(json["freq_khz"]) {
            mhz = String(format: "%.3f", khz / 1000)
        } else {
            mhz = "–"
        }
        band = text(json["band"], fallback: "–")
        dx = text(json["dx"], fallback: "–")
        mode = text(json["mode"], fallback: "")
        spotter = text(json["spotter"], fallback: "")
        country = text(json["country"], fallback: "")
        let comment = text(json["comment"], fallback: "")
        note = comment.uppercased() == mode.uppercased() ? "" : comment
        lat = number(json["lat"])
        lon = number(json["lon"])
    }
}

private struct LandMap {
    var polygons: [[[(Double, Double)]]] = []

    init(json: [String: Any]) {
        let features = json["features"] as? [[String: Any]] ?? []
        for feature in features {
            guard let geometry = feature["geometry"] as? [String: Any] else { continue }
            let type = geometry["type"] as? String ?? ""
            let coordinates = geometry["coordinates"] as? [Any] ?? []
            if type == "Polygon" {
                let rings = coordinates.compactMap(Self.ring)
                if !rings.isEmpty { polygons.append(rings) }
            } else if type == "MultiPolygon" {
                for polygon in coordinates {
                    guard let ringsAny = polygon as? [Any] else { continue }
                    let rings = ringsAny.compactMap(Self.ring)
                    if !rings.isEmpty { polygons.append(rings) }
                }
            }
        }
    }

    private static func ring(_ value: Any) -> [(Double, Double)]? {
        guard let points = value as? [Any] else { return nil }
        var ring: [(Double, Double)] = []
        for point in points {
            guard let pair = point as? [Any], pair.count >= 2,
                  let lon = number(pair[0]), let lat = number(pair[1]) else { continue }
            ring.append((lon, lat))
        }
        return ring.count >= 3 ? ring : nil
    }
}

private enum Palette {
    static let bg = NSColor(srgbRed: 0.031, green: 0.039, blue: 0.051, alpha: 1)
    static let ocean = NSColor(srgbRed: 0.047, green: 0.078, blue: 0.110, alpha: 1)
    static let land = NSColor(srgbRed: 0.102, green: 0.169, blue: 0.227, alpha: 1)
    static let coast = NSColor(srgbRed: 0.73, green: 0.81, blue: 0.86, alpha: 0.28)
    static let ink = NSColor(srgbRed: 0.902, green: 0.929, blue: 0.953, alpha: 1)
    static let dim = NSColor(srgbRed: 0.545, green: 0.608, blue: 0.671, alpha: 1)
    static let amber = NSColor(srgbRed: 0.894, green: 0.694, blue: 0.353, alpha: 1)
    static let amber2 = NSColor(srgbRed: 0.941, green: 0.843, blue: 0.651, alpha: 1)
    static let cyan = NSColor(srgbRed: 0.475, green: 0.816, blue: 0.769, alpha: 1)
    static let panel = NSColor(srgbRed: 0.055, green: 0.075, blue: 0.102, alpha: 0.94)
    static let good = NSColor(srgbRed: 0.561, green: 0.808, blue: 0.667, alpha: 1)
    static let fair = NSColor(srgbRed: 0.890, green: 0.761, blue: 0.478, alpha: 1)
    static let poor = NSColor(srgbRed: 0.878, green: 0.545, blue: 0.478, alpha: 1)
    static let grid = NSColor(white: 1, alpha: 0.05)
    static let night = NSColor(srgbRed: 0.008, green: 0.024, blue: 0.047, alpha: 0.62)
    static let dusk = NSColor(srgbRed: 0.494, green: 0.573, blue: 0.690, alpha: 0.22)
    static let greylineWide = NSColor(srgbRed: 0.84, green: 0.81, blue: 0.73, alpha: 0.28)
    static let greyline = NSColor(srgbRed: 0.94, green: 0.86, blue: 0.69, alpha: 0.92)
    static let sun = NSColor(srgbRed: 0.941, green: 0.765, blue: 0.416, alpha: 1)
    static let sunRing = NSColor(srgbRed: 0.941, green: 0.765, blue: 0.416, alpha: 0.45)

    static func font(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: weight)
    }

    static func mono(_ size: CGFloat) -> NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: size, weight: .medium)
    }

    static func band(_ name: String) -> NSColor {
        switch name {
        case "160m": return NSColor(srgbRed: 0.55, green: 0.42, blue: 0.29, alpha: 1)
        case "80m": return NSColor(srgbRed: 0.82, green: 0.42, blue: 0.42, alpha: 1)
        case "40m": return NSColor(srgbRed: 0.88, green: 0.63, blue: 0.35, alpha: 1)
        case "20m": return NSColor(srgbRed: 0.84, green: 0.82, blue: 0.42, alpha: 1)
        case "15m": return NSColor(srgbRed: 0.37, green: 0.78, blue: 0.69, alpha: 1)
        case "10m": return NSColor(srgbRed: 0.54, green: 0.48, blue: 0.88, alpha: 1)
        default: return amber2
        }
    }
}

private func text(_ value: Any?, fallback: String) -> String {
    if let string = value as? String {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }
    if let number = number(value) {
        return String(format: "%g", number)
    }
    return fallback
}

private func number(_ value: Any?) -> Double? {
    if value is NSNull || value == nil { return nil }
    if let number = value as? NSNumber { return number.doubleValue }
    if let string = value as? String, let parsed = Double(string) { return parsed }
    return nil
}

private func field(_ value: Any?, digits: Int?) -> String {
    guard let box = value as? [String: Any] else { return "–" }
    let raw = box["value"]
    if raw is NSNull || raw == nil { return "–" }
    if digits == nil {
        return text(raw, fallback: "–")
    }
    guard let number = number(raw) else { return text(raw, fallback: "–") }
    return String(format: "%.\(digits ?? 0)f", number)
}

private func fieldNumber(_ value: Any?) -> Double? {
    guard let box = value as? [String: Any] else { return nil }
    return number(box["value"])
}

private func short(_ value: Any?) -> String {
    if value is NSNull || value == nil { return "–" }
    return text(value, fallback: "–")
}

private func feedSummary(_ feeds: [String: Any]?) -> String {
    guard let feeds else { return "" }
    var parts: [String] = []
    for key in ["space_weather", "bands", "dx"] {
        guard let feed = feeds[key] as? [String: Any] else { continue }
        let name = text(feed["name"], fallback: key)
        let age = number(feed["age_sec"])
        let label: String
        if let age {
            if age < 90 { label = "\(Int(age))s" }
            else if age < 5400 { label = "\(Int(age / 60))m" }
            else { label = "\(Int(age / 3600))h" }
        } else {
            label = ""
        }
        let stale = (feed["stale"] as? Bool ?? false) ? " stale" : ""
        let empty = (feed["empty"] as? Bool ?? false) ? " empty" : ""
        parts.append("\(name) \(label)\(stale)\(empty)".trimmingCharacters(in: .whitespaces))
    }
    return parts.joined(separator: "   ")
}
