import SwiftUI

struct MessageBubbleView: View {
  let message: ChatMessage
  var onApprovalDecision: ((Bool) -> Void)? = nil

  var body: some View {
    switch message.kind {
    case .user(let text):
      HStack {
        Spacer(minLength: 48)
        Text(text)
          .padding(.horizontal, 14)
          .padding(.vertical, 10)
          .background(.tint, in: RoundedRectangle(cornerRadius: 18))
          .foregroundStyle(.white)
      }

    case .assistant(let text):
      HStack {
        Text(LocalizedStringKey(text))  // renders the model's markdown
          .padding(.horizontal, 14)
          .padding(.vertical, 10)
          .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
          .textSelection(.enabled)
        Spacer(minLength: 48)
      }

    case .toolActivity(let label, let state):
      HStack {
        ToolActivityView(label: label, state: state)
        Spacer()
      }

    case .approval(let details, let state):
      HStack {
        ApprovalCardView(details: details, state: state) { approved in
          onApprovalDecision?(approved)
        }
        Spacer(minLength: 48)
      }

    case .error(let text):
      HStack {
        Label(text, systemImage: "exclamationmark.triangle.fill")
          .font(.footnote)
          .foregroundStyle(.red)
          .padding(.horizontal, 14)
          .padding(.vertical, 8)
          .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
        Spacer(minLength: 48)
      }
    }
  }
}

struct ToolActivityView: View {
  let label: String
  let state: ToolActivityState

  var body: some View {
    HStack(spacing: 8) {
      switch state {
      case .running:
        ProgressView()
          .controlSize(.small)
      case .done:
        Image(systemName: "checkmark.circle.fill")
          .foregroundStyle(.green)
      case .failed:
        Image(systemName: "xmark.circle.fill")
          .foregroundStyle(.red)
      }
      Text(label)
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .background(Color(.tertiarySystemBackground), in: Capsule())
    .overlay(Capsule().strokeBorder(Color(.separator), lineWidth: 0.5))
  }
}
