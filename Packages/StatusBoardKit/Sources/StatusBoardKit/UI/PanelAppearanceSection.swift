#if !os(tvOS) && !os(watchOS)
import SwiftUI

/// The Appearance pages of the panel inspector: theme, background, glass and
/// blur, and the rules that let a panel restyle itself from its own data.
struct PanelAppearanceSection: View {
    @Binding var appearance: PanelAppearance
    @Binding var accentColorHex: String?
    /// What the panel is, so the dynamic explanation can be specific rather
    /// than generic.
    let kind: PanelKind
    /// Whether this panel is on a board with a backdrop worth masking.
    let boardHasBackdrop: Bool

    var body: some View {
        Section("Appearance") {
            Picker("Theme", selection: $appearance.theme) {
                ForEach(SBThemeName.allCases) { theme in
                    Text(theme.displayName).tag(theme)
                }
            }
            ColorPicker("Accent color", selection: Binding(
                get: { accentColorHex.flatMap(Color.init(hexString:))
                        ?? Color(hex: appearance.theme.palette.accent) },
                set: { accentColorHex = $0.hexString() }))
            if accentColorHex != nil {
                Button("Use Theme Accent") { accentColorHex = nil }
            }
            Toggle("Hide the title bar", isOn: $appearance.hidesTitleBar)
        }

        Section("Background") {
            Picker("Style", selection: $appearance.backgroundStyle) {
                ForEach(PanelBackgroundStyle.allCases) { style in
                    Text(style.displayName).tag(style)
                }
            }
            backgroundControls
        }

        Section("Transparency and Blur") {
            slider("Background opacity", value: $appearance.backgroundOpacity,
                   range: 0...1, format: .percent)
            slider("Content opacity", value: $appearance.contentOpacity,
                   range: 0.2...1, format: .percent)
            slider("Background blur", value: $appearance.backgroundBlur,
                   range: 0...40, format: .points)
            slider("Darken behind content", value: $appearance.scrim,
                   range: 0...0.85, format: .percent)
            Picker("Frosted glass", selection: $appearance.material) {
                ForEach(PanelMaterialStyle.allCases) { material in
                    Text(material.displayName).tag(material)
                }
            }
            Text("Glass blurs whatever is behind the panel — the board's wallpaper, or the desktop through a transparent window. Turn the background opacity down to let it through.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }

        Section("Shape") {
            slider("Corner radius",
                   value: Binding(
                       get: { appearance.cornerRadius ?? appearance.theme.palette.cornerRadius },
                       set: { appearance.cornerRadius = $0 }),
                   range: 0...36, format: .points)
            if appearance.cornerRadius != nil {
                Button("Use Theme Shape") { appearance.cornerRadius = nil }
            }
            slider("Border width",
                   value: Binding(get: { appearance.borderWidth ?? 1 },
                                  set: { appearance.borderWidth = $0 }),
                   range: 0...6, format: .points)
            ColorPicker("Border color", selection: Binding(
                get: { appearance.resolvedBorderColor(theme: appearance.theme) },
                set: { appearance.borderColorHex = $0.hexString() }))
            if appearance.borderColorHex != nil {
                Button("Use Theme Border") { appearance.borderColorHex = nil }
            }
            slider("Glow", value: $appearance.glowRadius, range: 0...24, format: .points)
        }

        Section("Text") {
            ColorPicker("Text color", selection: Binding(
                get: { appearance.textColorHex.flatMap(Color.init(hexString:))
                        ?? Color(hex: appearance.theme.palette.textPrimary) },
                set: { appearance.textColorHex = $0.hexString() }))
            ColorPicker("Secondary text", selection: Binding(
                get: { appearance.secondaryTextColorHex.flatMap(Color.init(hexString:))
                        ?? Color(hex: appearance.theme.palette.textSecondary) },
                set: { appearance.secondaryTextColorHex = $0.hexString() }))
            if appearance.textColorHex != nil || appearance.secondaryTextColorHex != nil {
                Button("Use Theme Text Colors") {
                    appearance.textColorHex = nil
                    appearance.secondaryTextColorHex = nil
                }
            }
        }

        Section("Live Styling") {
            Picker("Change with the data", selection: $appearance.dynamic) {
                ForEach(DynamicAppearanceMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            if appearance.dynamic != .off {
                slider("Strength", value: $appearance.dynamicIntensity,
                       range: 0...1, format: .percent)
                Toggle("Animate", isOn: $appearance.animates)
                Text(dynamicExplanation)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if appearance.animates && appearance.dynamic != .off {
                Text("Motion is switched off automatically when Reduce Motion is on, and in exported board images.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }

        Section {
            Button("Reset Appearance", role: .destructive) {
                appearance = PanelAppearance()
            }
            .disabled(appearance.isDefault)
        }
    }

    // MARK: - Background controls

    @ViewBuilder
    private var backgroundControls: some View {
        switch appearance.backgroundStyle {
        case .theme:
            Text("Follows the theme above — and the board's theme, when the panel is set to Status Board and the board has told its panels to match.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .solid:
            ColorPicker("Color", selection: Binding(
                get: { appearance.backgroundColorHex.flatMap(Color.init(hexString:))
                        ?? Color(hex: appearance.theme.palette.background.first ?? 0x191D23) },
                set: { appearance.backgroundColorHex = $0.hexString() }))
        case .gradient:
            gradientEditor
        case .image:
            TextField("Image URL", text: Binding(
                get: { appearance.backgroundImageURL ?? "" },
                set: { appearance.backgroundImageURL = $0.isEmpty ? nil : $0 }))
                .autocorrectionOff()
            Picker("Fit", selection: $appearance.imageFill) {
                ForEach(BackgroundImageFill.allCases) { fill in
                    Text(fill.displayName).tag(fill)
                }
            }
            if let url = appearance.backgroundImageURL, !url.isEmpty {
                Button("Reload Image") { SBBackdropImageStore.shared.forget(url) }
            }
            Text("The image is downloaded once and cached on this device. Turn up “Darken behind content” if the picture is fighting the text.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .boardBackdrop:
            if boardHasBackdrop {
                Text("This panel shows its own slice of the board's background, lined up with every other panel doing the same — one picture, cut apart by the gaps between panels.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Label("The board has no background set yet. Add a wallpaper or an image in Board Appearance, then this panel will mask it.",
                      systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        case .material:
            Text("Nothing but blur. Pick a glass thickness below.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .clear:
            Text("The board shows straight through. Useful over a wallpaper, with the border turned down to nothing.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var gradientEditor: some View {
        ForEach(Array(appearance.gradientColorHexes.enumerated()), id: \.offset) { index, hex in
            ColorPicker("Color \(index + 1)", selection: Binding(
                get: { Color(hexString: hex) ?? .gray },
                set: { newValue in
                    guard let updated = newValue.hexString(),
                          appearance.gradientColorHexes.indices.contains(index) else { return }
                    appearance.gradientColorHexes[index] = updated
                }))
        }
        .onDelete { appearance.gradientColorHexes.remove(atOffsets: $0) }
        Button("Add Color") {
            appearance.gradientColorHexes.append(
                appearance.gradientColorHexes.isEmpty ? "#1E293B" : "#38BDF8")
        }
        .disabled(appearance.gradientColorHexes.count >= 5)
        slider("Angle", value: $appearance.gradientAngle, range: 0...360, format: .degrees)
    }

    // MARK: - Helpers

    private var dynamicExplanation: String {
        switch appearance.dynamic {
        case .off:
            return ""
        case .weather:
            return "An animated sky behind the panel: the right cloud cover, rain or snow when there is any, and the sun or the moon depending on whether it is light where the forecast is from."
        case .status:
            return "Washes the panel green, amber or red from what it is showing — services being up, work being late, a grade slipping."
        case .threshold:
            return "Follows this panel's own alert limits, so what is on screen agrees with the notifications it sends."
        case .timeOfDay:
            return "Shifts through dawn, day, dusk and night colors on its own."
        case .automatic:
            switch kind {
            case .weather:
                return "A weather panel gets an animated sky matching the current conditions and the time of day."
            case .status:
                return "Colors the panel by the worst service state it is showing."
            case .grades, .assignments:
                return "Colors the panel by how much is late or slipping."
            case .graph, .progress, .bridge, .mcp, .health:
                return "Follows this panel's alert limits when it has any, and stays out of the way when it does not."
            case .clock:
                return "Shifts through dawn, day, dusk and night colors."
            default:
                return "Restyles the panel when its data says something worth showing — otherwise the appearance above is used as-is."
            }
        }
    }

    private enum SliderFormat { case percent, points, degrees }

    @ViewBuilder
    private func slider(_ title: String, value: Binding<Double>,
                        range: ClosedRange<Double>, format: SliderFormat) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(formatted(value.wrappedValue, as: format))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: value, in: range)
        }
    }

    private func formatted(_ value: Double, as format: SliderFormat) -> String {
        switch format {
        case .percent: return "\(Int((value * 100).rounded()))%"
        case .points: return "\(Int(value.rounded())) pt"
        case .degrees: return "\(Int(value.rounded()))°"
        }
    }
}
#endif
