import SwiftUI

/// Inline gate in front of irreversible agent actions (sends, withdrawals), rendered
/// as a card in the chat transcript. The agent loop stays suspended until the user
/// decides; after the decision the card stays behind as an approved/declined record.
struct ApprovalCardView: View {
  let details: ConfirmationDetails
  let state: ApprovalState
  let onDecision: (Bool) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 8) {
        Image(systemName: "paperplane.circle.fill")
          .font(.title3)
          .foregroundStyle(.tint)
        Text(details.title)
          .font(.subheadline.bold())
        Spacer()
        statusBadge
      }

      VStack(spacing: 0) {
        ForEach(details.fields) { field in
          HStack(alignment: .top) {
            Text(field.label)
              .foregroundStyle(.secondary)
            Spacer()
            Text(field.value)
              .font(.footnote.monospaced())
              .multilineTextAlignment(.trailing)
              .textSelection(.enabled)
          }
          .font(.footnote)
          .padding(.vertical, 8)
          if field.id != details.fields.last?.id {
            Divider()
          }
        }
      }
      .padding(.horizontal, 12)
      .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 10))

      if state == .pending, let warning = details.warning {
        Label(warning, systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.orange)
      }

      if state == .pending {
        HStack(spacing: 10) {
          Button {
            onDecision(false)
          } label: {
            Text("Decline")
              .font(.subheadline)
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(.bordered)

          Button {
            onDecision(true)
          } label: {
            Text("Approve")
              .font(.subheadline)
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(.borderedProminent)
        }
      }
    }
    .padding(14)
    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
    .overlay(
      RoundedRectangle(cornerRadius: 18)
        .strokeBorder(state == .pending ? Color.accentColor.opacity(0.5) : Color(.separator), lineWidth: 1)
    )
  }

  @ViewBuilder
  private var statusBadge: some View {
    switch state {
    case .pending:
      Text("Needs approval")
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.orange.opacity(0.15), in: Capsule())
        .foregroundStyle(.orange)
    case .approved:
      Label("Approved", systemImage: "checkmark.circle.fill")
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.green.opacity(0.15), in: Capsule())
        .foregroundStyle(.green)
    case .declined:
      Label("Declined", systemImage: "xmark.circle.fill")
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.red.opacity(0.15), in: Capsule())
        .foregroundStyle(.red)
    }
  }
}
