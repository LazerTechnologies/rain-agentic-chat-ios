import Foundation
import TurnkeySwift

/// App-side glue that drives Turnkey's Swift SDK end-to-end (configure, email OTP, wallet
/// provisioning) so the app can hand a ready `TurnkeyContext` to `RainService.initialize(turnkey:)`.
/// Rain SDK intentionally does not own Turnkey auth.
@MainActor
final class TurnkeyAuthService {
  static let shared = TurnkeyAuthService()

  /// Minimum session lifetime (seconds) still worth resuming.
  private static let minRemainingSeconds: TimeInterval = 30

  /// `TurnkeyContext.configure` is one-shot for the process lifetime; false until it has run.
  private var isConfigured = false

  /// OTP handles carried from `sendEmailOtp` to `verifyEmailOtp`.
  private var pendingOtp: (id: String, bundle: String, email: String)?

  private init() {}

  /// True when the local config carries the Turnkey org / auth proxy ids this flow needs.
  var isAvailable: Bool {
    !AgentLocalConfig.turnkeyOrganizationId.isEmpty
      && !AgentLocalConfig.turnkeyAuthProxyConfigId.isEmpty
  }

  /// Hand this to `RainService.initialize(turnkey:)` once auth is complete.
  var context: TurnkeyContext {
    get throws { try configure() }
  }

  /// Configures the Turnkey singleton from local config. Idempotent.
  @discardableResult
  func configure() throws -> TurnkeyContext {
    guard isAvailable else { throw TurnkeyAuthError.notConfigured }
    if !isConfigured {
      TurnkeyContext.configure(
        TurnkeyConfig(
          organizationId: AgentLocalConfig.turnkeyOrganizationId,
          authProxyConfigId: AgentLocalConfig.turnkeyAuthProxyConfigId
        )
      )
      isConfigured = true
    }
    return TurnkeyContext.shared
  }

  /// True when Turnkey restored an authenticated, unexpired session from the Keychain (skips OTP).
  func hasActiveSession() -> Bool {
    guard isConfigured, let session = TurnkeyContext.shared.session else { return false }
    return session.exp > Date().timeIntervalSince1970 + Self.minRemainingSeconds
  }

  /// Same answer as ``hasActiveSession()``, for callers running at launch.
  ///
  /// `configure` kicks off the Keychain restore in a detached task, so `session` is still nil for
  /// a beat afterwards — reading it straight away reports "no session" for a user who has one.
  /// Waits for `authState` to settle (and the session to land with it) before answering.
  func awaitRestoredSession(timeout: Duration = .seconds(3)) async -> Bool {
    guard isConfigured else { return false }
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
      switch TurnkeyContext.shared.authState {
      case .unAuthenticated:
        return false
      case .authenticated where TurnkeyContext.shared.session != nil:
        return hasActiveSession()
      case .authenticated, .loading:
        break
      }
      try? await Task.sleep(for: .milliseconds(50))
    }
    return hasActiveSession()
  }

  /// Clears the stored session (full logout). Safe no-op when none exists.
  func logout() {
    pendingOtp = nil
    guard isConfigured else { return }
    TurnkeyContext.shared.clearSession(for: TurnkeySwift.Constants.Session.defaultSessionKey)
  }

  /// Sends an email OTP. Any restored session is dropped first — reaching this screen means the
  /// user is logging in deliberately, possibly as somebody else.
  func sendEmailOtp(email: String) async throws {
    try configure()
    if hasActiveSession() { logout() }
    let result = try await TurnkeyVendor.initEmailOtp(email: email)
    pendingOtp = (id: result.otpId, bundle: result.otpEncryptionTargetBundle, email: email)
  }

  /// Verifies the OTP code and creates a session, then ensures an Ethereum account exists.
  /// `completeOtp` handles first-time signup and returning login transparently.
  func verifyEmailOtp(code: String) async throws {
    guard let pending = pendingOtp else { throw TurnkeyAuthError.noPendingOtp }
    let context = try configure()
    // Turnkey throws `keyAlreadyExists` rather than overwriting a session under the default key.
    context.clearSession(for: TurnkeySwift.Constants.Session.defaultSessionKey)
    try await TurnkeyVendor.completeEmailOtp(
      otpId: pending.id,
      code: code,
      bundle: pending.bundle,
      email: pending.email
    )
    pendingOtp = nil
    try await ensureEthereumWallet()
  }

  /// Ensures the authenticated sub-org has an Ethereum-format account (secp256k1), creating a
  /// wallet on first login. Rain resolves the EVM address from this account.
  func ensureEthereumWallet() async throws {
    try configure()
    try await TurnkeyVendor.ensureEthereumWallet()
  }
}

/// Turnkey's async calls off the main actor.
///
/// `TurnkeyContext` is a nonisolated vendor type, so these run where Turnkey expects them to;
/// hopping a main-actor-isolated reference into them is what Swift 6 flags. Rain makes the same
/// bet in its own `TurnkeyConfig` under the same host contract: finish authentication before
/// handing the context over, and don't re-auth / log out while calls are in flight.
private enum TurnkeyVendor {
  static func initEmailOtp(email: String) async throws -> InitOtpResult {
    try await TurnkeyContext.shared.initOtp(contact: email, otpType: .email)
  }

  static func completeEmailOtp(
    otpId: String,
    code: String,
    bundle: String,
    email: String
  ) async throws {
    _ = try await TurnkeyContext.shared.completeOtp(
      otpId: otpId,
      otpCode: code,
      otpEncryptionTargetBundle: bundle,
      contact: email,
      otpType: .email,
      invalidateExisting: true
    )
  }

  static func ensureEthereumWallet() async throws {
    let context = TurnkeyContext.shared
    try await context.refreshWallets()
    let hasAccount = context.wallets
      .flatMap(\.accounts)
      .contains { $0.addressFormat == .address_format_ethereum }
    guard !hasAccount else { return }

    try await context.createWallet(
      walletName: "Rain Agent Demo Wallet",
      accounts: [
        WalletAccountParams(
          addressFormat: .address_format_ethereum,
          curve: .curve_secp256k1,
          path: "m/44'/60'/0'/0/0",
          pathFormat: .path_format_bip32
        )
      ],
      mnemonicLength: 12
    )
  }
}

enum TurnkeyAuthError: LocalizedError {
  case notConfigured
  case noPendingOtp

  var errorDescription: String? {
    switch self {
    case .notConfigured:
      return "Turnkey is not configured. Set turnkeyOrganizationId and turnkeyAuthProxyConfigId "
        + "in AgentLocalConfig.swift."
    case .noPendingOtp:
      return "Request a Turnkey login code before verifying one."
    }
  }
}
