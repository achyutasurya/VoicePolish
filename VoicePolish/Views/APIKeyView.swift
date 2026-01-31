import SwiftUI

struct APIKeyView: View {
    let title: String
    let placeholder: String
    @Binding var apiKey: String
    let isValid: Bool
    let errorMessage: String
    var credits: String? = nil
    let onVerify: () async -> Void

    @State private var isVerifying = false
    @State private var tempKey = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.bold())

            HStack {
                SecureField(placeholder, text: $tempKey)
                    .textFieldStyle(.roundedBorder)
                    .onAppear { tempKey = apiKey }

                Button("Verify") {
                    apiKey = tempKey
                    Task {
                        isVerifying = true
                        await onVerify()
                        isVerifying = false
                    }
                }
                .disabled(tempKey.isEmpty || isVerifying)
            }

            HStack(spacing: 4) {
                if isVerifying {
                    ProgressView()
                        .controlSize(.small)
                    Text("Verifying...")
                } else if isValid {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    if let credits {
                        Text(credits)
                    } else {
                        Text("Valid")
                    }
                } else if !errorMessage.isEmpty {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.red)
                    Text(errorMessage)
                }
            }
            .font(.caption)
        }
    }
}
