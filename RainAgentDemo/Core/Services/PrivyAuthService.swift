import Foundation
import PrivySDK

/// App-side glue that drives Privy's iOS SDK end-to-end (init, email OTP, embedded-wallet
/// provisioning). Rain SDK intentionally does not own Privy auth.
@MainActor
final class PrivyAuthService {
  static let shared = PrivyAuthService()

  /// Privy must be a single instance for the app's lifetime; hold it here after init.
  private var instance: (any Privy)?

  private init() {}

  /// True when the local config carries the Privy ids this flow needs.
  var isAvailable: Bool {
    !AgentLocalConfig.privyAppId.isEmpty && !AgentLocalConfig.privyAppClientId.isEmpty
  }

  /// Hand this to `RainService.initialize(privy:)` once auth is complete.
  var privy: any Privy {
    get throws {
      guard let instance else { throw PrivyAuthError.notConfigured }
      return instance
    }
  }

  /// Initializes the Privy singleton (idempotent; reuses the existing instance).
  func initialize(appId: String, appClientId: String) {
    guard instance == nil else { return }
    instance = PrivySdk.initialize(
      config: PrivyConfig(appId: appId, appClientId: appClientId)
    )
  }

  /// True when Privy restored an authenticated session from a prior run (skips the OTP round-trip).
  /// `getAuthState()` awaits Privy's readiness itself, so this is safe to call at launch.
  func hasActiveSession() async -> Bool {
    guard let instance else { return false }
    if case .authenticated = await instance.getAuthState() { return true }
    return false
  }

  /// Logs the Privy user out. Safe no-op if not authenticated.
  func logout() async {
    guard let user = await instance?.getUser() else { return }
    await user.logout()
  }

  /// Sends an email OTP. Throws on failure.
  func sendEmailOtp(email: String) async throws {
    try await privy.email.sendCode(to: email)
  }

  /// Verifies the OTP and creates a Privy session, then ensures an embedded Ethereum wallet exists.
  func verifyEmailOtp(code: String, email: String) async throws {
    _ = try await privy.email.loginWithCode(code, sentTo: email)
    try await ensureEthereumWallet()
  }

  /// Ensures the authenticated user has an embedded Ethereum wallet, creating one if needed.
  func ensureEthereumWallet() async throws {
    let instance = try privy
    guard let user = await instance.getUser() else { throw PrivyAuthError.notAuthenticated }
    if user.embeddedEthereumWallets.isEmpty {
      _ = try await user.createEthereumWallet(allowAdditional: false)
    }
  }
}

enum PrivyAuthError: LocalizedError {
  case notConfigured
  case notAuthenticated

  var errorDescription: String? {
    switch self {
    case .notConfigured:
      return "Privy is not configured. Set privyAppId and privyAppClientId in AgentLocalConfig.swift."
    case .notAuthenticated:
      return "Privy user not authenticated."
    }
  }
}
