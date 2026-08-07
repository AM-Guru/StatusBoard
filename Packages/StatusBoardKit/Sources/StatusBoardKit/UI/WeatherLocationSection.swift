#if !os(tvOS) && !os(watchOS)
import SwiftUI

/// Picking where a weather panel reports from.
///
/// Whichever way the location is chosen, the resolved coordinates are written
/// back into the panel — a city search, a station lookup and Current Location
/// all end with a latitude and longitude on file. That is what lets the panel
/// keep working when the geocoder is unreachable, when location permission is
/// later withdrawn, or when the board is opened on a device that has never
/// been to that screen.
struct WeatherLocationSection: View {
    @Binding var settings: PanelSettings

    @State private var searchText = ""
    @State private var results: [GeocodedPlace] = []
    @State private var isWorking = false
    @State private var message: String?
    @State private var messageIsError = false

    var body: some View {
        Section("Location") {
            Picker("Look up by", selection: $settings.weatherLocationMode) {
                ForEach(WeatherLocationMode.allCases) { mode in
                    Label(mode.displayName, systemImage: mode.symbolName).tag(mode)
                }
            }
            switch settings.weatherLocationMode {
            case .coordinates: coordinateFields
            case .place: placeFields
            case .station: stationFields
            case .personal: personalFields
            case .current: currentLocationFields
            }
            if let message {
                Label(message, systemImage: messageIsError
                      ? "exclamationmark.triangle" : "checkmark.circle")
                    .font(.footnote)
                    .foregroundStyle(messageIsError ? SBTheme.bad : SBTheme.good)
            }
        }
        Section("Units") {
            Picker("Temperature", selection: $settings.weatherUnits) {
                ForEach(WeatherUnits.allCases) { unit in
                    Text(unit.displayName).tag(unit)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    // MARK: - Coordinates

    private var coordinateFields: some View {
        Group {
            TextField("Name", text: optional($settings.locationName))
            TextField("Latitude", text: optionalNumber($settings.latitude))
            TextField("Longitude", text: optionalNumber($settings.longitude))
        }
    }

    // MARK: - City or address

    @ViewBuilder
    private var placeFields: some View {
        HStack {
            TextField("City, postcode or address", text: $searchText)
                .autocorrectionOff()
                .onSubmit { search() }
            Button("Search", action: search)
                .disabled(searchText.trimmingCharacters(in: .whitespaces).isEmpty || isWorking)
        }
        if isWorking { ProgressView().controlSize(.small) }
        ForEach(results) { place in
            Button {
                choose(place)
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(place.name).foregroundStyle(.primary)
                    if !place.detail.isEmpty {
                        Text(place.detail).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)
        }
        if settings.weatherPlaceQuery != nil {
            LabeledContent("Using") { Text(settings.weatherLocationSummary) }
        }
        Text("Towns and cities are matched by name; a street address or postcode is resolved on this device. The coordinates are saved, so the panel keeps working if the lookup service is unreachable later.")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    // MARK: - Public station

    @ViewBuilder
    private var stationFields: some View {
        Picker("Network", selection: $settings.weatherStationNetwork) {
            ForEach(WeatherStationNetwork.allCases) { network in
                Text(network.displayName).tag(network)
            }
        }
        HStack {
            TextField("Station ID", text: optional($settings.weatherStationID))
                .autocorrectionOff()
                .onSubmit { checkStation() }
            Button("Check", action: checkStation)
                .disabled((settings.weatherStationID ?? "").isEmpty || isWorking)
        }
        if isWorking { ProgressView().controlSize(.small) }
        Text(settings.weatherStationNetwork.hint)
            .font(.footnote)
            .foregroundStyle(.secondary)
        Text("Current conditions come from the station itself. The five-day strip still comes from the forecast for the station's own coordinates.")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    // MARK: - Personal station

    @ViewBuilder
    private var personalFields: some View {
        TextField("Station URL (JSON)", text: optional($settings.weatherPersonalURL))
            .autocorrectionOff()
        Picker("Format", selection: $settings.weatherPersonalFormat) {
            ForEach(PersonalWeatherFormat.allCases) { format in
                Text(format.displayName).tag(format)
            }
        }
        if settings.weatherPersonalFormat == .custom {
            ForEach(PersonalWeatherField.allCases) { field in
                TextField("\(field.displayName) path", text: Binding(
                    get: { settings.weatherPersonalPaths[field.rawValue] ?? "" },
                    set: { newValue in
                        if newValue.isEmpty {
                            settings.weatherPersonalPaths.removeValue(forKey: field.rawValue)
                        } else {
                            settings.weatherPersonalPaths[field.rawValue] = newValue
                        }
                    }))
                    .autocorrectionOff()
            }
        }
        HStack {
            Button("Test Connection", action: testPersonalStation)
                .disabled((settings.weatherPersonalURL ?? "").isEmpty || isWorking)
            if isWorking { ProgressView().controlSize(.small) }
        }
        TextField("Name shown on the panel", text: optional($settings.locationName))
        Text("Reads your own station directly on your network — nothing goes through anyone else's server. Ecowitt, Ambient Weather, WeeWX, WeatherFlow and Home Assistant are recognised automatically; anything else can point at exact JSON paths.")
            .font(.footnote)
            .foregroundStyle(.secondary)
        Text("Set coordinates too, under Coordinates, if you want the five-day forecast alongside your own readings.")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    // MARK: - Current location

    @ViewBuilder
    private var currentLocationFields: some View {
        HStack {
            Button("Use My Location", action: useCurrentLocation)
                .disabled(isWorking)
            if isWorking { ProgressView().controlSize(.small) }
        }
        if let known = WeatherLocationProvider.lastKnown {
            LabeledContent("Last fix") { Text(known.name) }
        }
        Text("The panel follows this device. Its position is used to fetch the forecast and is kept on the device — it is never sent anywhere else, and other devices showing this board report on their own location.")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    // MARK: - Actions

    private func search() {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        isWorking = true
        message = nil
        Task {
            let found = await WeatherGeocoder.search(query)
            results = found
            isWorking = false
            if found.isEmpty {
                show("No place matched “\(query)”", isError: true)
            }
        }
    }

    private func choose(_ place: GeocodedPlace) {
        settings.latitude = place.latitude
        settings.longitude = place.longitude
        settings.locationName = place.name
        settings.weatherPlaceQuery = place.displayName
        WeatherLocationCache.remember(place, for: place.displayName)
        results = []
        searchText = ""
        show("Using \(place.displayName)", isError: false)
    }

    private func checkStation() {
        guard let id = settings.weatherStationID, !id.isEmpty else { return }
        isWorking = true
        message = nil
        Task {
            do {
                let reading = try await StationWeatherSource.fetch(
                    id: id, network: settings.weatherStationNetwork)
                if let latitude = reading.latitude, let longitude = reading.longitude {
                    settings.latitude = latitude
                    settings.longitude = longitude
                }
                if settings.locationName == nil { settings.locationName = reading.stationName }
                show("\(reading.stationName): \(Int(reading.temperatureC.rounded()))°C, "
                     + reading.conditionText.lowercased(), isError: false)
            } catch {
                show(error.localizedDescription, isError: true)
            }
            isWorking = false
        }
    }

    private func testPersonalStation() {
        isWorking = true
        message = nil
        let snapshot = settings
        Task {
            do {
                let reading = try await PersonalWeatherSource.fetch(settings: snapshot)
                show("Read \(Int(reading.temperatureC.rounded()))°C from your station",
                     isError: false)
            } catch {
                show(error.localizedDescription, isError: true)
            }
            isWorking = false
        }
    }

    private func useCurrentLocation() {
        isWorking = true
        message = nil
        Task {
            do {
                let place = try await WeatherLocationProvider.shared.currentPlace()
                settings.latitude = place.latitude
                settings.longitude = place.longitude
                settings.locationName = place.name
                show("Found \(place.name)", isError: false)
            } catch {
                show(error.localizedDescription, isError: true)
            }
            isWorking = false
        }
    }

    private func show(_ text: String, isError: Bool) {
        message = text
        messageIsError = isError
    }

    // MARK: - Binding helpers

    private func optional(_ source: Binding<String?>) -> Binding<String> {
        Binding(get: { source.wrappedValue ?? "" },
                set: { source.wrappedValue = $0.isEmpty ? nil : $0 })
    }

    private func optionalNumber(_ source: Binding<Double?>) -> Binding<String> {
        Binding(get: { source.wrappedValue.map { String($0) } ?? "" },
                set: { source.wrappedValue = Double($0) })
    }
}
#endif
