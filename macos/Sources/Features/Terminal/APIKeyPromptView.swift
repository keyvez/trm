import SwiftUI

/// A sheet that prompts the user to enter their Claude API key.
struct APIKeyPromptView: View {
    @Binding var isPresented: Bool
    var onSave: (String) -> Void

    @State private var apiKey: String = ""

    var body: some View {
        VStack(spacing: 16) {
            Text("Enter Claude API Key")
                .font(.headline)

            Text("Your API key is stored locally and used to communicate with the Claude API.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            SecureField("sk-ant-...", text: $apiKey)
                .textFieldStyle(.roundedBorder)
                .frame(width: 340)
                .onSubmit { save() }

            HStack(spacing: 12) {
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(apiKey.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 400)
    }

    private func save() {
        guard !apiKey.isEmpty else { return }
        onSave(apiKey)
        isPresented = false
    }
}
