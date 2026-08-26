import SwiftUI

struct PresenterView: View {
    let text: String
    var fontSize: CGFloat = 32
    let onDismiss: () -> Void

    @State private var currentFontSize: CGFloat

    init(text: String, fontSize: CGFloat = 32, onDismiss: @escaping () -> Void) {
        self.text = text
        self.fontSize = fontSize
        self.onDismiss = onDismiss
        _currentFontSize = State(initialValue: fontSize)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()

                HStack(spacing: 16) {
                    Button {
                        currentFontSize = max(16, currentFontSize - 4)
                    } label: {
                        Image(systemName: "textformat.size.smaller")
                            .font(.title2)
                    }

                    Button {
                        currentFontSize = min(72, currentFontSize + 4)
                    } label: {
                        Image(systemName: "textformat.size.larger")
                            .font(.title2)
                    }
                }
                .foregroundStyle(.white.opacity(0.7))
                .padding(.trailing, 8)

                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title)
                }
                .padding()
            }

            Spacer()

            ScrollView {
                Text(text.isEmpty ? "No text to display." : text)
                    .font(.system(size: currentFontSize, weight: .regular, design: .serif))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                    .frame(maxWidth: .infinity)
            }

            Spacer()
        }
        .background(Color.black.ignoresSafeArea())
    }
}
