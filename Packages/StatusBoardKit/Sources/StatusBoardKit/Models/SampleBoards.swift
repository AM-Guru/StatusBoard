import Foundation

extension Dashboard {
    /// A board built to show what the appearance system can do: a wallpaper
    /// running underneath everything, panels that mask their own slice of it
    /// so one picture reads across the board, frosted glass over the top, and
    /// a weather panel that paints its own sky.
    public static func glassGallery() -> Dashboard {
        func settings(_ configure: (inout PanelSettings) -> Void) -> PanelSettings {
            var value = PanelSettings()
            configure(&value)
            return value
        }

        var board = Dashboard(name: "Glass")
        board.grid = BoardGrid(columns: 8, rows: 4)

        var appearance = BoardAppearance()
        appearance.theme = .glass
        appearance.wallpaper = .aurora
        // Roomier gaps: the space between panels is what cuts the wallpaper
        // apart, so a tight grid hides the effect entirely.
        appearance.panelSpacing = 16
        board.appearance = appearance

        /// Frosted, borderless, showing the board through itself.
        func glass(_ configure: (inout PanelAppearance) -> Void = { _ in }) -> PanelAppearance {
            var look = PanelAppearance()
            look.theme = .glass
            look.backgroundStyle = .clear
            look.material = .thin
            look.borderWidth = 0
            look.cornerRadius = 18
            configure(&look)
            return look
        }

        /// Shows its own piece of the wallpaper, lined up with its neighbours.
        func masked(_ configure: (inout PanelAppearance) -> Void = { _ in }) -> PanelAppearance {
            var look = PanelAppearance()
            look.theme = .glass
            look.backgroundStyle = .boardBackdrop
            look.scrim = 0.35
            look.borderWidth = 0
            look.cornerRadius = 18
            configure(&look)
            return look
        }

        board.panels = [
            Panel(kind: .weather, title: "Weather",
                  frame: GridRect(x: 0, y: 0, width: 4, height: 2),
                  settings: settings {
                      $0.latitude = 37.7749
                      $0.longitude = -122.4194
                      $0.locationName = "San Francisco"
                      $0.weatherLocationMode = .coordinates
                      // The sky is the background, so the chrome gets out of
                      // its way entirely.
                      var look = PanelAppearance()
                      look.theme = .glass
                      look.backgroundStyle = .clear
                      look.borderWidth = 0
                      look.cornerRadius = 18
                      look.dynamic = .weather
                      look.hidesTitleBar = true
                      $0.appearance = look
                  }),
            Panel(kind: .clock, title: "Clock",
                  frame: GridRect(x: 4, y: 0, width: 2, height: 1),
                  settings: settings {
                      $0.showsSeconds = false
                      $0.appearance = masked()
                  }),
            Panel(kind: .countdown, title: "Launch",
                  frame: GridRect(x: 6, y: 0, width: 2, height: 1),
                  settings: settings {
                      $0.targetDate = Calendar.current.date(byAdding: .day, value: 30, to: Date())
                      $0.appearance = masked()
                  }),
            Panel(kind: .progress, title: "CPU",
                  frame: GridRect(x: 4, y: 1, width: 2, height: 1),
                  settings: settings {
                      $0.bridgeKey = "mac.cpu"
                      $0.progressFormat = .circle
                      $0.appearance = glass()
                  }),
            Panel(kind: .progress, title: "Memory",
                  frame: GridRect(x: 6, y: 1, width: 2, height: 1),
                  settings: settings {
                      $0.bridgeKey = "mac.memory"
                      $0.progressFormat = .gradient
                      $0.appearance = glass()
                  }),
            Panel(kind: .graph, title: "Mac CPU",
                  frame: GridRect(x: 0, y: 2, width: 5, height: 2),
                  settings: settings {
                      $0.bridgeKey = "mac.cpu.history"
                      $0.chartStyle = .area
                      $0.appearance = masked { $0.scrim = 0.45 }
                  }),
            Panel(kind: .text, title: "About",
                  frame: GridRect(x: 5, y: 2, width: 3, height: 2),
                  settings: settings {
                      $0.text = "Every panel here is see-through. The three across the middle each show their own slice of the same wallpaper — move one and it re-cuts. Board Appearance changes the picture behind all of them."
                      $0.appearance = glass { $0.scrim = 0.25 }
                  }),
        ]
        return board
    }

    /// A house at a glance: room temperatures, what the doors are doing, the
    /// thermostat, its trend and its health.
    ///
    /// It is built on HomeKit because that is the one provider that needs no
    /// setup at all — the accessories are already paired. Changing each
    /// panel's kind to Home Assistant or Nest in its settings keeps the
    /// layout and swaps the source.
    public static func homeBoard() -> Dashboard {
        func settings(_ configure: (inout PanelSettings) -> Void) -> PanelSettings {
            var value = PanelSettings()
            value.refreshSeconds = PanelKind.homeKit.defaultRefreshSeconds
            configure(&value)
            return value
        }

        var board = Dashboard(name: "Home")
        board.grid = BoardGrid(columns: 8, rows: 5)

        board.panels = [
            Panel(kind: .homeKit, title: "Rooms",
                  frame: GridRect(x: 0, y: 0, width: 5, height: 2),
                  settings: settings { $0.homeMode = .rooms }),
            Panel(kind: .homeKit, title: "Thermostat",
                  frame: GridRect(x: 5, y: 0, width: 3, height: 2),
                  settings: settings { $0.homeMode = .thermostat }),
            Panel(kind: .homeKit, title: "Temperature Trend",
                  frame: GridRect(x: 0, y: 2, width: 5, height: 2),
                  settings: settings {
                      $0.homeMode = .trend
                      $0.hvacTrendHours = 12
                  }),
            Panel(kind: .homeKit, title: "Equipment Health",
                  frame: GridRect(x: 5, y: 2, width: 3, height: 3),
                  settings: settings {
                      $0.homeMode = .diagnostics
                      $0.hvacTrendHours = 24
                  }),
            Panel(kind: .homeKit, title: "Doors & Motion",
                  frame: GridRect(x: 0, y: 4, width: 5, height: 1),
                  settings: settings { $0.homeMode = .activity }),
        ]
        return board
    }
}
