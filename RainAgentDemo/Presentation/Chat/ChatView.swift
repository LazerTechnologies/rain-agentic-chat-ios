import SwiftUI

struct ChatView: View {
  @EnvironmentObject private var appState: AppState
  @StateObject private var viewModel = ChatViewModel()
  @State private var draft = ""

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        messagesList
        if viewModel.isRunning && viewModel.pendingConfirmation == nil {
          typingIndicator
        }
        InputBarView(
          text: $draft,
          isDisabled: viewModel.isRunning
        ) {
          viewModel.send(draft)
          draft = ""
        }
      }
      .navigationTitle("Rain Assistant")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .principal) {
          Image("RainLogo")
            .resizable()
            .scaledToFit()
            .frame(height: 16)
            .accessibilityLabel("Rain Assistant")
        }
        ToolbarItem(placement: .topBarLeading) {
          VStack(alignment: .leading, spacing: 0) {
            Text(viewModel.shortAddress)
              .font(.caption.monospaced())
            Text(viewModel.chain.displayName)
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
        }
        ToolbarItem(placement: .topBarTrailing) {
          Menu {
            Section(viewModel.provider.map { "Signed in with \($0.displayName)" } ?? "Account") {
              Button(role: .destructive) {
                Task { await appState.logout() }
              } label: {
                Label("Log out", systemImage: "rectangle.portrait.and.arrow.right")
              }
            }
          } label: {
            Image(systemName: "person.crop.circle")
          }
        }
      }
    }
  }

  private var messagesList: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 12) {
          if viewModel.messages.isEmpty {
            emptyState
          }
          ForEach(viewModel.messages) { message in
            MessageBubbleView(message: message) { approved in
              viewModel.resolveConfirmation(approved: approved)
            }
            .id(message.id)
          }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 16)
      }
      .onChange(of: viewModel.messages.count) {
        if let last = viewModel.messages.last {
          withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(last.id, anchor: .bottom)
          }
        }
      }
    }
  }

  private var emptyState: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 6) {
        Text("Hi! I'm your Rain wallet assistant.")
          .font(.headline)
        Text("I can check balances, analyze your activity, send funds (with your confirmation), and manage your card collateral.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
      .padding(.top, 24)

      VStack(alignment: .leading, spacing: 8) {
        ForEach(ChatViewModel.suggestedPrompts, id: \.self) { prompt in
          Button {
            viewModel.send(prompt)
          } label: {
            Text(prompt)
              .font(.subheadline)
              .padding(.horizontal, 14)
              .padding(.vertical, 8)
              .background(Color(.secondarySystemBackground), in: Capsule())
          }
          .buttonStyle(.plain)
          .disabled(viewModel.isRunning)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var typingIndicator: some View {
    HStack(spacing: 8) {
      ProgressView()
        .controlSize(.small)
      Text("Thinking…")
        .font(.footnote)
        .foregroundStyle(.secondary)
      Spacer()
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 6)
  }
}
