#if !os(watchOS)
import SwiftUI

/// In-app, searchable documentation generated from `IntegrationCatalog`.
public struct IntegrationGuideView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    public init() {}

    private var results: [IntegrationDescriptor] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return IntegrationCatalog.all }
        return IntegrationCatalog.all.filter {
            [$0.kind.displayName, $0.dataSource, $0.configuration, $0.platforms]
                .joined(separator: " ")
                .localizedCaseInsensitiveContains(query)
        }
    }

    public var body: some View {
        NavigationStack {
            List {
                Section("Automation key") {
                    capabilityRow("Terminal / sbctl", detail: "Bridge Value, Graph, Progress")
                    capabilityRow("App Intents & Siri", detail: "Push Value and Get Value by bridge key")
                    capabilityRow("WidgetKit", detail: "Every panel; choose a specific shared panel in widget settings")
                    capabilityRow("Apple TV fallback", detail: "The Mac bridge relays every available snapshot")
                }
                ForEach(results) { item in
                    Section {
                        LabeledContent("Data source", value: item.dataSource)
                        Text(item.configuration)
                        LabeledContent("Platforms", value: item.platforms)
                        LabeledContent("Apple TV", value: item.appleTVDelivery)
                        capabilityGrid(item)
                    } header: {
                        Label(item.kind.displayName, systemImage: item.kind.symbolName)
                    }
                }
            }
            .navigationTitle("Integrations")
            .searchable(text: $search, prompt: "Search data sources")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 620, minHeight: 620)
        #endif
    }

    private func capabilityRow(_ title: String, detail: String) -> some View {
        LabeledContent(title, value: detail)
    }

    private func capabilityGrid(_ item: IntegrationDescriptor) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
            GridRow {
                support(item.acceptsTerminalInput, "Terminal")
                support(item.supportsAppIntents, "App Intents")
            }
            GridRow {
                support(item.supportsSiri, "Siri")
                support(item.supportsWidgetKit, "WidgetKit")
            }
        }
        .font(.caption)
    }

    private func support(_ supported: Bool, _ label: String) -> some View {
        Label(label, systemImage: supported ? "checkmark.circle.fill" : "minus.circle")
            .foregroundStyle(supported ? SBTheme.good : .secondary)
    }
}
#endif
