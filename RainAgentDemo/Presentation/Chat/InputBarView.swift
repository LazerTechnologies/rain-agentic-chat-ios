import SwiftUI

struct InputBarView: View {
  @Binding var text: String
  var isDisabled: Bool
  var onSend: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      TextField("Ask about your wallet…", text: $text, axis: .vertical)
        .lineLimit(1...4)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
        .onSubmit { submit() }
        .disabled(isDisabled)

      Button(action: submit) {
        Image(systemName: "arrow.up.circle.fill")
          .font(.system(size: 30))
      }
      .disabled(isDisabled || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(.bar)
  }

  private func submit() {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    onSend()
  }
}
