import SwiftUI

/// Horizontal row of quick-action pill buttons displayed at the bottom-trailing
/// corner of a terminal pane.
struct QuickActionsOverlayView: View {
    let actions: [QuickAction]
    let executingActionId: UUID?
    let onExecute: (QuickAction) -> Void
    let onDelete: (QuickAction) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(actions) { action in
                QuickActionPill(
                    action: action,
                    isExecuting: executingActionId == action.id,
                    onExecute: { onExecute(action) },
                    onDelete: { onDelete(action) }
                )
            }
        }
    }
}

/// A single quick-action pill: green for commands, purple for scripts.
/// Click to execute, hover to reveal an X button for deletion.
struct QuickActionPill: View {
    let action: QuickAction
    let isExecuting: Bool
    let onExecute: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false

    private static let commandColor = Color(red: 0x34/255, green: 0xC7/255, blue: 0x59/255)
    private static let scriptColor = Color(red: 0x9B/255, green: 0x59/255, blue: 0xF0/255)

    private var pillColor: Color {
        action.isScript ? Self.scriptColor : Self.commandColor
    }

    private var defaultIcon: String? {
        if let icon = action.icon { return icon }
        return action.isScript ? "brain" : nil
    }

    private var tooltipText: String {
        action.isScript ? action.script : action.command
    }

    var body: some View {
        HStack(spacing: 4) {
            // Delete button (visible on hover)
            if isHovering && !isExecuting {
                Button(action: onDelete) {
                    Image(systemName: "xmark")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundColor(.white.opacity(0.8))
                }
                .buttonStyle(.plain)
                .transition(.opacity)
                .help("Remove quick action")
            }

            // Icon + label
            Button(action: onExecute) {
                HStack(spacing: 4) {
                    if isExecuting {
                        ProgressView()
                            .controlSize(.mini)
                            .scaleEffect(0.6)
                            .frame(width: 10, height: 10)
                    } else if let icon = defaultIcon {
                        Image(systemName: icon)
                            .font(.system(size: 9, weight: .medium))
                    }
                    Text(action.name)
                        .font(.system(size: 10, weight: .medium))
                        .lineLimit(1)
                }
                .foregroundColor(.white)
            }
            .buttonStyle(.plain)
            .disabled(isExecuting)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(pillColor.opacity(isHovering ? 1.0 : 0.75))
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .help(tooltipText)
    }
}

// MARK: - Script Action Editor Sheet

/// A sheet for creating a new script action.
struct ScriptActionEditorSheet: View {
    @Binding var isPresented: Bool
    let paneWatermark: String
    let availablePanes: [PanePickerItem]
    let onSave: (String, String, String?) -> Void  // (name, script, icon?)

    @State private var name = ""
    @State private var script = ""
    @State private var icon = ""

    var body: some View {
        VStack(spacing: 16) {
            Text("New Script Action")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                Text("Name")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                TextField("e.g. Grab WS URL", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Script")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Text("Describe what to do in natural language. Use # to reference panes.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                ScriptEditorField(text: $script, availablePanes: availablePanes)
                    .frame(minHeight: 80, maxHeight: 160)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    )
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Icon (optional)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                TextField("SF Symbol name, e.g. brain", text: $icon)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Save") {
                    onSave(name, script, icon.isEmpty ? nil : icon)
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.isEmpty || script.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}
