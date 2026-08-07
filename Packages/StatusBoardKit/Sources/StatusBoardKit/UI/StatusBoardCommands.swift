#if !os(tvOS) && !os(watchOS)
import SwiftUI

/// Keyboard-driven menu commands, shared by the Mac app's menu bar and the
/// iPad's hardware-keyboard menu (hold ⌘ to see them).
public struct StatusBoardCommands: Commands {
    let model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Board") {
                model.store.add(Dashboard(name: "New Board"))
            }
            .keyboardShortcut("n", modifiers: .command)

            Menu("New Board from Sample") {
                Button("Mac Vitals") { model.store.add(.macVitals()) }
                Button("World Clocks") { model.store.add(.worldClocks()) }
                Button("Clock Faces") { model.store.add(.clockFaces()) }
            }
        }

        CommandGroup(replacing: .undoRedo) {
            Button(model.store.undoActionName.map { "Undo \($0)" } ?? "Undo") {
                model.store.undo()
            }
            .keyboardShortcut("z", modifiers: .command)
            .disabled(!model.store.canUndo)

            Button(model.store.redoActionName.map { "Redo \($0)" } ?? "Redo") {
                model.store.redo()
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(!model.store.canRedo)
        }

        CommandMenu("Board") {
            Toggle("Edit Layout", isOn: Binding(
                get: { model.isEditing },
                set: { model.isEditing = $0 }))
                .keyboardShortcut("e", modifiers: .command)

            Button("Refresh All Panels") {
                model.refreshVisibleBoard()
            }
            .keyboardShortcut("r", modifiers: .command)

            Menu("Arrange For") {
                Button("This \(SBDeviceClass.current.displayName)") {
                    model.layoutTarget = nil
                }
                Divider()
                // Same gate as the toolbar's screen menu: the glasses are only a
                // screen while something is linked to draw them.
                ForEach(SBDeviceFamily.allCases.filter {
                    !$0.requiresLink || model.glassesLink.isOffered
                }) { family in
                    if family.layouts.count > 1 {
                        // The screens that turn carry one arrangement per
                        // orientation, so each is its own choice here.
                        Menu(family.displayName) {
                            ForEach(family.layouts) { device in
                                Button(device.orientation.displayName) {
                                    model.layoutTarget = device
                                    model.isEditing = true
                                }
                            }
                        }
                    } else {
                        Button(family.displayName) {
                            model.layoutTarget = family.primaryLayout
                            model.isEditing = true
                        }
                    }
                }
            }
            .disabled(model.store.selectedDashboard == nil)

            Button("Layout Options") {
                model.showsLayoutInspector.toggle()
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(model.layoutTarget == nil)

            Divider()

            Button("Duplicate Panel") {
                guard let target = model.commandTargetPanel() else { return }
                if let copy = model.store.duplicatePanel(id: target.panel.id,
                                                         in: target.dashboardID) {
                    model.selectedPanelID = copy.id
                }
            }
            .keyboardShortcut("d", modifiers: .command)
            .disabled(model.commandTargetPanel() == nil)

            Button("Copy Panel") {
                guard let target = model.commandTargetPanel() else { return }
                PanelPasteboard.copy(target.panel)
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(model.commandTargetPanel() == nil)

            Button("Paste Panel") {
                guard let panel = PanelPasteboard.paste(),
                      let boardID = model.store.selectedDashboard?.id else { return }
                if let inserted = model.store.insertPanel(panel, into: boardID) {
                    model.isEditing = true
                    model.selectedPanelID = inserted.id
                }
            }
            .keyboardShortcut("v", modifiers: [.command, .shift])
            .disabled(model.store.selectedDashboard == nil)

            Divider()

            Menu("Add Panel") {
                ForEach(PanelKind.allCases) { kind in
                    Button(kind.displayName) {
                        guard let boardID = model.store.selectedDashboard?.id,
                              let panel = model.store.addPanel(kind: kind, to: boardID) else { return }
                        model.isEditing = true
                        model.selectedPanelID = panel.id
                        model.inspectedPanelID = panel.id
                    }
                }
            }
            .disabled(model.store.selectedDashboard == nil)

            Divider()

            Button("Duplicate Board") {
                if let id = model.store.selectedDashboard?.id {
                    model.store.duplicate(id: id)
                }
            }
            .keyboardShortcut("d", modifiers: [.command, .option])
            .disabled(model.store.selectedDashboard == nil)

            Button("Delete Board", role: .destructive) {
                if let id = model.store.selectedDashboard?.id {
                    model.store.delete(id: id)
                }
            }
            .disabled(model.store.selectedDashboard == nil)
        }
    }
}
#endif
