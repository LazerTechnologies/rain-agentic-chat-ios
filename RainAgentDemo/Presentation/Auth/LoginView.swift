import SwiftUI

struct LoginView: View {
  @EnvironmentObject private var appState: AppState
  @StateObject private var viewModel = LoginViewModel()

  var body: some View {
    VStack(spacing: 24) {
      Spacer()

      VStack(spacing: 8) {
        Image("RainLogo")
          .resizable()
          .scaledToFit()
          .frame(height: 40)
          .accessibilityLabel("Rain")
        Text("Wallet Assistant")
          .font(.title.bold())
        Text("Chat with an AI agent that manages your Rain wallet")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      }

      if appState.phase == .connecting {
        connectingView
      } else {
        providerPicker
        formView
      }

      if let error = appState.bootError ?? viewModel.errorMessage {
        Text(error)
          .font(.footnote)
          .foregroundStyle(.red)
          .multilineTextAlignment(.center)
      }

      Spacer()
      Spacer()
    }
    .padding(.horizontal, 32)
  }

  /// Which wallet provider signs this session. Both resolve to the same Rain client surface;
  /// only the login flow and key custody differ.
  private var providerPicker: some View {
    VStack(spacing: 6) {
      Picker("Wallet provider", selection: $appState.provider) {
        ForEach(WalletProviderKind.allCases) { provider in
          Text(provider.displayName).tag(provider)
        }
      }
      .pickerStyle(.segmented)
      .disabled(viewModel.isBusy)
      .onChange(of: appState.provider) {
        viewModel.backToEmail()
      }

      if !viewModel.isAvailable(appState.provider) {
        Text(viewModel.unavailableMessage(appState.provider))
          .font(.caption)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      }
    }
  }

  private var connectingView: some View {
    VStack(spacing: 12) {
      ProgressView()
      Text("Connecting your wallet…")
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
    .padding(.top, 16)
  }

  @ViewBuilder
  private var formView: some View {
    switch viewModel.step {
    case .email:
      VStack(spacing: 16) {
        TextField("Email address", text: $viewModel.email)
          .textFieldStyle(.roundedBorder)
          .keyboardType(.emailAddress)
          .textContentType(.emailAddress)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()

        Button {
          Task { await viewModel.sendCode(provider: appState.provider) }
        } label: {
          busyLabel("Send login code")
        }
        .buttonStyle(.borderedProminent)
        .disabled(!viewModel.canSubmitEmail || !viewModel.isAvailable(appState.provider))
      }

    case .otp:
      VStack(spacing: 16) {
        Text("Enter the code sent to \(viewModel.email)")
          .font(.footnote)
          .foregroundStyle(.secondary)

        TextField("6-digit code", text: $viewModel.code)
          .textFieldStyle(.roundedBorder)
          .keyboardType(.numberPad)
          .textContentType(.oneTimeCode)
          .multilineTextAlignment(.center)

        Button {
          Task {
            if await viewModel.verifyCode(provider: appState.provider) {
              await appState.connect()
            }
          }
        } label: {
          busyLabel("Verify & connect")
        }
        .buttonStyle(.borderedProminent)
        .disabled(!viewModel.canSubmitCode)

        Button("Use a different email") {
          viewModel.backToEmail()
        }
        .font(.footnote)
      }
    }
  }

  private func busyLabel(_ title: String) -> some View {
    Group {
      if viewModel.isBusy {
        ProgressView().frame(maxWidth: .infinity)
      } else {
        Text(title).frame(maxWidth: .infinity)
      }
    }
    .padding(.vertical, 4)
  }
}
