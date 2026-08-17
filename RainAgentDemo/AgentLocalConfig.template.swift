import Foundation

/// Per-developer local config. Copy this file to `AgentLocalConfig.swift` (git-ignored)
/// and fill in real values before building:
///
///   cp AgentLocalConfig.template.swift AgentLocalConfig.swift
///
/// The Anthropic key ships inside the app binary here strictly because this is a demo.
/// A production app routes Anthropic traffic through a backend proxy that owns the key.
enum AgentLocalConfig {
  /// Anthropic API key (console.anthropic.com). Demo only; see note above.
  /// Leave empty when using the Claude proxy below.
  static let anthropicAPIKey = ""

  /// Claude proxy base URL, e.g. "https://claude-proxy.example.com". When set, all
  /// Claude traffic goes to `<claudeProxyBaseURL>/v1/chat/completions` (OpenAI wire
  /// format, translated in OpenAIProxy.swift) instead of api.anthropic.com. Leave
  /// empty to call Anthropic directly.
  static let claudeProxyBaseURL = ""

  /// Auth token for the Claude proxy. Sent as both `Authorization: Bearer <token>`
  /// and `x-api-key` so it works with either style of proxy.
  static let claudeProxyToken = ""

  /// Model id as the proxy names it (see the proxy's /v1/models), e.g. "claude-opus-4.8".
  static let claudeProxyModel = ""

  /// Privy app id (Privy dashboard).
  static let privyAppId = ""

  /// Privy app client id (Privy dashboard -> app settings -> clients).
  static let privyAppClientId = ""

  /// Turnkey organization ID (Turnkey dashboard). Required to sign in with Turnkey.
  static let turnkeyOrganizationId = ""

  /// Turnkey auth proxy config ID (Turnkey dashboard -> Auth Proxy). Required to sign in
  /// with Turnkey; the email-OTP flow runs through the proxy.
  static let turnkeyAuthProxyConfigId = ""

  /// Rain issuing API key (dev environment). Optional: collateral tools need it,
  /// balance/send/history tools work without it.
  static let rainApiKey = ""

  /// Rain userId matching the API key. Optional, see above.
  static let rainUserId = ""

  /// Network the assistant operates on by default.
  static let defaultChain: WalletChain = .baseSepolia
}
