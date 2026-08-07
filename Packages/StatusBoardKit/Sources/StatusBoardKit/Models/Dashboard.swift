import Foundation

/// A single board: a named grid of panels. Boards sync via iCloud.
public struct Dashboard: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var grid: BoardGrid
    public var panels: [Panel]
    public var createdAt: Date
    public var modifiedAt: Date
    /// Per-screen arrangements, keyed by `SBDeviceClass.rawValue`. A device with
    /// no entry here follows `grid` and each panel's own `frame`.
    public var deviceLayouts: [String: BoardLayout]
    /// The board's own look: theme, wallpaper, and the backdrop panels mask
    /// through when they are set to `PanelBackgroundStyle.boardBackdrop`.
    public var appearance: BoardAppearance

    public init(id: UUID = UUID(), name: String, grid: BoardGrid = BoardGrid(),
                panels: [Panel] = [], createdAt: Date = Date(), modifiedAt: Date = Date(),
                deviceLayouts: [String: BoardLayout] = [:],
                appearance: BoardAppearance = BoardAppearance()) {
        self.id = id
        self.name = name
        self.grid = grid
        self.panels = panels
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.deviceLayouts = deviceLayouts
        self.appearance = appearance
    }

    /// Hand-written so boards saved before per-device layouts existed — on disk
    /// here or already in iCloud — still decode.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        grid = try container.decode(BoardGrid.self, forKey: .grid)
        panels = try container.decode([Panel].self, forKey: .panels)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        modifiedAt = try container.decode(Date.self, forKey: .modifiedAt)
        deviceLayouts = try container.decodeIfPresent([String: BoardLayout].self,
                                                      forKey: .deviceLayouts) ?? [:]
        appearance = try container.decodeIfPresent(BoardAppearance.self,
                                                   forKey: .appearance) ?? BoardAppearance()
    }

    /// The first slot that fits, or nil when the board is full.
    public func freeFrame(width: Int, height: Int) -> GridRect? {
        let clampedWidth = min(width, grid.columns)
        guard grid.rows >= height else { return nil }
        for y in 0...(grid.rows - height) {
            for x in 0...(max(0, grid.columns - clampedWidth)) {
                let candidate = GridRect(x: x, y: y, width: clampedWidth, height: height)
                if !panels.contains(where: { $0.frame.intersects(candidate) }) {
                    return candidate
                }
            }
        }
        return nil
    }

    public func firstFreeFrame(width: Int, height: Int) -> GridRect {
        freeFrame(width: width, height: height)
            ?? GridRect(x: 0, y: 0, width: width, height: height)
    }

    /// Reserves a slot for a new panel, growing the board downward when the
    /// grid is already full — otherwise new panels would silently stack on
    /// top of existing ones.
    public mutating func makeRoom(width: Int, height: Int) -> GridRect {
        if let free = freeFrame(width: width, height: height) { return free }
        let y = grid.rows
        grid.rows += height
        return GridRect(x: 0, y: y, width: min(width, grid.columns), height: height)
    }

    /// A standalone copy of this board under a new name.
    ///
    /// The board and every panel get fresh identities so the copy syncs as its
    /// own board rather than fighting the original for the same record. The
    /// per-device layouts are keyed by panel ID, so they are remapped onto the
    /// new panels — otherwise the copy would silently lose every Apple TV and
    /// Watch arrangement the original was tuned for.
    public func duplicated(name: String, now: Date = Date()) -> Dashboard {
        var copy = self
        copy.id = UUID()
        copy.name = name
        copy.createdAt = now
        copy.modifiedAt = now

        var newIDs: [String: String] = [:]
        for index in copy.panels.indices {
            let fresh = UUID()
            newIDs[copy.panels[index].id.uuidString] = fresh.uuidString
            copy.panels[index].id = fresh
        }
        copy.deviceLayouts = copy.deviceLayouts.mapValues { layout in
            var remapped = layout
            remapped.frames = [:]
            for (panelID, frame) in layout.frames {
                guard let fresh = newIDs[panelID] else { continue }
                remapped.frames[fresh] = frame
            }
            remapped.hiddenPanelIDs = Set(layout.hiddenPanelIDs.compactMap { newIDs[$0] })
            return remapped
        }
        return copy
    }
}

/// The logical grid a board is laid out on. Panels position themselves in grid units.
public struct BoardGrid: Codable, Hashable, Sendable {
    public var columns: Int
    public var rows: Int

    public init(columns: Int = 8, rows: Int = 4) {
        self.columns = columns
        self.rows = rows
    }
}

/// Integer rectangle in grid units.
public struct GridRect: Codable, Hashable, Sendable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = max(1, width)
        self.height = max(1, height)
    }

    public func intersects(_ other: GridRect) -> Bool {
        x < other.x + other.width && other.x < x + width &&
        y < other.y + other.height && other.y < y + height
    }

    public func clamped(to grid: BoardGrid) -> GridRect {
        var rect = self
        rect.width = min(rect.width, grid.columns)
        rect.height = min(rect.height, grid.rows)
        rect.x = min(max(0, rect.x), grid.columns - rect.width)
        rect.y = min(max(0, rect.y), grid.rows - rect.height)
        return rect
    }
}

extension Dashboard {
    /// Curated boards offered in the "New Board" menu.
    public static func macVitals() -> Dashboard {
        var board = Dashboard(name: "Mac Vitals")
        func settings(_ configure: (inout PanelSettings) -> Void) -> PanelSettings {
            var value = PanelSettings()
            configure(&value)
            return value
        }
        board.panels = [
            Panel(kind: .clock, title: "Clock", frame: GridRect(x: 0, y: 0, width: 2, height: 1)),
            Panel(kind: .progress, title: "CPU", frame: GridRect(x: 2, y: 0, width: 2, height: 1),
                  settings: settings { $0.bridgeKey = "mac.cpu"; $0.progressFormat = .circle }),
            Panel(kind: .progress, title: "Memory", frame: GridRect(x: 4, y: 0, width: 2, height: 1),
                  settings: settings { $0.bridgeKey = "mac.memory"; $0.progressFormat = .gradient
                                       $0.accentColorHex = "#35C4B5" }),
            Panel(kind: .progress, title: "Disk", frame: GridRect(x: 6, y: 0, width: 2, height: 1),
                  settings: settings { $0.bridgeKey = "mac.disk"; $0.progressFormat = .stack
                                       $0.accentColorHex = "#4CD964" }),
            Panel(kind: .graph, title: "Mac CPU", frame: GridRect(x: 0, y: 1, width: 4, height: 2),
                  settings: settings { $0.bridgeKey = "mac.cpu.history"; $0.chartStyle = .area }),
            Panel(kind: .graph, title: "Network In", frame: GridRect(x: 4, y: 1, width: 2, height: 1),
                  settings: settings { $0.bridgeKey = "mac.net.in.history"; $0.chartStyle = .waveform
                                       $0.accentColorHex = "#35C4B5" }),
            Panel(kind: .graph, title: "Network Out", frame: GridRect(x: 6, y: 1, width: 2, height: 1),
                  settings: settings { $0.bridgeKey = "mac.net.out.history"; $0.chartStyle = .waveform
                                       $0.accentColorHex = "#FF6B9D" }),
            Panel(kind: .graph, title: "Memory Pressure", frame: GridRect(x: 4, y: 2, width: 4, height: 1),
                  settings: settings { $0.bridgeKey = "mac.memory.history"; $0.chartStyle = .smooth
                                       $0.accentColorHex = "#35C4B5" }),
            Panel(kind: .bridge, title: "Uptime", frame: GridRect(x: 0, y: 3, width: 2, height: 1),
                  settings: settings { $0.bridgeKey = "mac.uptime" }),
            Panel(kind: .graph, title: "Disk Used", frame: GridRect(x: 2, y: 3, width: 2, height: 1),
                  settings: settings { $0.bridgeKey = "mac.disk.history"; $0.chartStyle = .bar
                                       $0.accentColorHex = "#4CD964" }),
            Panel(kind: .text, title: "About", frame: GridRect(x: 4, y: 3, width: 4, height: 1),
                  settings: settings { $0.text = "Every panel here fills automatically while the Mac app runs." }),
        ]
        return board
    }

    public static func worldClocks() -> Dashboard {
        var board = Dashboard(name: "World Clocks")
        let zones: [(String, String, UInt32)] = [
            ("Cupertino", "America/Los_Angeles", 0xFFA028),
            ("New York", "America/New_York", 0x35C4B5),
            ("London", "Europe/London", 0xFF6B9D),
            ("Berlin", "Europe/Berlin", 0x4CD964),
            ("Tokyo", "Asia/Tokyo", 0xBF5AF2),
            ("Sydney", "Australia/Sydney", 0xFFCC00),
        ]
        for (index, zone) in zones.enumerated() {
            var settings = PanelSettings()
            settings.timeZoneID = zone.1
            settings.showsSeconds = false
            settings.accentColorHex = String(format: "#%06X", zone.2)
            board.panels.append(
                Panel(kind: .clock, title: zone.0,
                      frame: GridRect(x: (index % 2) * 4, y: index / 2, width: 4, height: 1),
                      settings: settings))
        }
        board.grid = BoardGrid(columns: 8, rows: 3)
        return board
    }

    /// The board seeded on first launch, echoing the classic Status Board layout.
    public static func starter() -> Dashboard {
        var board = Dashboard(name: "My Status Board")
        board.panels = [
            Panel(kind: .clock, title: "Clock",
                  frame: GridRect(x: 0, y: 0, width: 2, height: 1)),
            Panel(kind: .weather, title: "Weather",
                  frame: GridRect(x: 2, y: 0, width: 3, height: 1),
                  settings: {
                      var settings = PanelSettings()
                      settings.latitude = 37.7749
                      settings.longitude = -122.4194
                      settings.locationName = "San Francisco"
                      return settings
                  }()),
            Panel(kind: .countdown, title: "Launch",
                  frame: GridRect(x: 5, y: 0, width: 3, height: 1),
                  settings: {
                      var settings = PanelSettings()
                      settings.targetDate = Calendar.current.date(byAdding: .day, value: 30, to: Date())
                      return settings
                  }()),
            Panel(kind: .feed, title: "News",
                  frame: GridRect(x: 0, y: 1, width: 4, height: 2),
                  settings: {
                      var settings = PanelSettings()
                      settings.feedSources = [
                          FeedSource(url: "https://developer.apple.com/news/rss/news.rss"),
                          FeedSource(url: "https://www.swift.org/atom.xml"),
                      ]
                      settings.url = settings.feedSources.first?.url
                      return settings
                  }()),
            Panel(kind: .graph, title: "Mac CPU",
                  frame: GridRect(x: 4, y: 1, width: 4, height: 2),
                  settings: {
                      var settings = PanelSettings()
                      settings.bridgeKey = "mac.cpu.history"
                      settings.chartStyle = .area
                      return settings
                  }()),
            Panel(kind: .text, title: "Welcome",
                  frame: GridRect(x: 0, y: 3, width: 8, height: 1),
                  settings: {
                      var settings = PanelSettings()
                      settings.text = "Open Status Board on your Mac and the CPU graph fills itself. Push your own data:  curl -X POST http://<mac>:7311/api/push -d '{\"key\":\"cpu\",\"number\":42,\"history\":120}'"
                      return settings
                  }()),
        ]
        return board
    }
}
