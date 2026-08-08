# StatusBoard contributor instructions

When adding or changing a panel, data source, platform fallback, terminal input,
App Intent, Siri phrase, or WidgetKit support, update `IntegrationCatalog` in the
same change. The in-app Integrations guide is generated from that catalog. Keep
its `descriptor(for:)`, `source(for:)`, `configuration(for:)`, platform, and
Apple TV delivery switches exhaustive; do not add a default case. Update the
catalog coverage tests whenever capability semantics change.
