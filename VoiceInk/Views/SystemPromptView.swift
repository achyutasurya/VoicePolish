import SwiftUI

struct SystemPromptView: View {
    @Binding var systemPrompt: String
    @State private var tempPrompt = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("System Prompt")
                .font(.subheadline.bold())

            TextEditor(text: $tempPrompt)
                .font(.body.monospaced())
                .frame(height: 100)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                )
                .onAppear { tempPrompt = systemPrompt }

            HStack {
                Button("Save") {
                    systemPrompt = tempPrompt
                }

                Button("Reset to Default") {
                    tempPrompt = AppSettings.defaultSystemPrompt
                    systemPrompt = tempPrompt
                }
            }
        }
    }
}
