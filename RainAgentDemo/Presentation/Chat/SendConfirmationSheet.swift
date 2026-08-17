import SwiftUI

/// Native gate in front of irreversible agent actions (sends, withdrawals). The agent loop
/// stays suspended until the user decides; swipe-dismiss is blocked so the decision is explicit.
struct SendConfirmationSheet: View {
  let confirmation: PendingConfirmation
  let onDecision: (Bool) -> Void

  var body: some View {
    NavigationStack {
      VStack(spacing: 24) {
        Image(systemName: "paperplane.circle.fill")
          .font(.system(size: 56))
          .foregroundStyle(.tint)
          .padding(.top, 24)

        Text(confirmation.details.title)
          .font(.title2.bold())
          .multilineTextAlignment(.center)

        VStack(spacing: 0) {
          ForEach(confirmation.details.fields) { field in
            HStack(alignment: .top) {
              Text(field.label)
                .foregroundStyle(.secondary)
              Spacer()
              Text(field.value)
                .font(.callout.monospaced())
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
            }
            .padding(.vertical, 10)
            if field.id != confirmation.details.fields.last?.id {
              Divider()
            }
          }
        }
        .padding(.horizontal, 16)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))

        if let warning = confirmation.details.warning {
          Label(warning, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote)
            .foregroundStyle(.orange)
        }

        Spacer()

        VStack(spacing: 12) {
          Button {
            onDecision(true)
          } label: {
            Text("Confirm")
              .frame(maxWidth: .infinity)
              .padding(.vertical, 6)
          }
          .buttonStyle(.borderedProminent)

          Button {
            onDecision(false)
          } label: {
            Text("Cancel")
              .frame(maxWidth: .infinity)
              .padding(.vertical, 6)
          }
          .buttonStyle(.bordered)
        }
      }
      .padding(.horizontal, 24)
      .padding(.bottom, 16)
      .interactiveDismissDisabled()
    }
    .presentationDetents([.medium, .large])
  }
}
