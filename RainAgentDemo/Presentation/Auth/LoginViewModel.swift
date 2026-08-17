import Foundation

@MainActor
final class LoginViewModel: ObservableObject {
  enum Step {
    case email
    case otp
  }

  @Published var step: Step = .email
  @Published var email = ""
  @Published var code = ""
  @Published var isBusy = false
  @Published var errorMessage: String?

  private let privyAuth = PrivyAuthService.shared
  private let turnkeyAuth = TurnkeyAuthService.shared

  var canSubmitEmail: Bool {
    email.contains("@") && email.contains(".") && !isBusy
  }

  var canSubmitCode: Bool {
    code.count >= 4 && !isBusy
  }

  /// Whether a provider has the credentials its flow needs (both come from AgentLocalConfig).
  func isAvailable(_ provider: WalletProviderKind) -> Bool {
    switch provider {
    case .privy: return privyAuth.isAvailable
    case .turnkey: return turnkeyAuth.isAvailable
    }
  }

  func unavailableMessage(_ provider: WalletProviderKind) -> String {
    switch provider {
    case .privy:
      return "Set privyAppId and privyAppClientId in AgentLocalConfig.swift to sign in with Privy."
    case .turnkey:
      return "Set turnkeyOrganizationId and turnkeyAuthProxyConfigId in AgentLocalConfig.swift "
        + "to sign in with Turnkey."
    }
  }

  func sendCode(provider: WalletProviderKind) async {
    isBusy = true
    errorMessage = nil
    do {
      switch provider {
      case .privy: try await privyAuth.sendEmailOtp(email: email)
      case .turnkey: try await turnkeyAuth.sendEmailOtp(email: email)
      }
      step = .otp
    } catch {
      errorMessage = "Couldn't send the code: \(error.localizedDescription)"
    }
    isBusy = false
  }

  /// Verifies the OTP; on success the caller (AppState) connects the Rain SDK.
  func verifyCode(provider: WalletProviderKind) async -> Bool {
    isBusy = true
    errorMessage = nil
    defer { isBusy = false }
    do {
      switch provider {
      case .privy: try await privyAuth.verifyEmailOtp(code: code, email: email)
      case .turnkey: try await turnkeyAuth.verifyEmailOtp(code: code)
      }
      return true
    } catch {
      errorMessage = "Verification failed: \(error.localizedDescription)"
      return false
    }
  }

  /// Back to the email step, e.g. after switching provider or to use a different address.
  func backToEmail() {
    step = .email
    code = ""
    errorMessage = nil
  }
}
