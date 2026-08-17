import Foundation

/// Per-developer config. Fill in the values below before building; the file ships empty.
/// Keep your filled-in copy local — do not commit real keys.
///
/// The Anthropic key ships inside the app binary here strictly because this is a demo.
/// A production app routes Anthropic traffic through a backend proxy that owns the key.
enum AgentLocalConfig {
  /// Anthropic API key (console.anthropic.com). Demo only; leave empty when using the proxy below.
  /// e.g. "sk-ant-api03-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
  static let anthropicAPIKey = ""

  /// Claude proxy base URL. When set, Claude traffic goes to `<base>/v1/chat/completions`
  /// (OpenAI wire format, translated in OpenAIProxy.swift). e.g. "https://proxy.example.com"
  static let claudeProxyBaseURL = ""

  /// Auth token for the Claude proxy, sent as both `Authorization: Bearer` and `x-api-key`.
  /// e.g. "prx-0123456789abcdef0123456789abcdef"
  static let claudeProxyToken = ""

  /// Model id as the proxy names it (see the proxy's /v1/models).
  /// e.g. "claude-opus-5"
  static let claudeProxyModel = ""

  /// Privy app id (Privy dashboard).
  /// e.g. "clx0a1b2c3d4e5f6g7h8i9j0k1"
  static let privyAppId = ""

  /// Privy app client id (Privy dashboard -> app settings -> clients).
  /// e.g. "client-XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"
  static let privyAppClientId = ""

  /// Turnkey organization ID (Turnkey dashboard). Required to sign in with Turnkey.
  /// e.g. "00000000-1111-2222-3333-444444444444"
  static let turnkeyOrganizationId = ""

  /// Turnkey auth proxy config ID (Turnkey dashboard -> Auth Proxy), for the email-OTP flow.
  /// e.g. "55555555-6666-7777-8888-999999999999"
  static let turnkeyAuthProxyConfigId = ""

  /// Rain issuing API key (dev). Optional: collateral tools need it, wallet tools don't.
  /// e.g. "0123456789abcdef0123456789abcdef01234567" (40 hex chars)
  static let rainApiKey = ""

  /// Rain userId matching the API key. Optional, see above.
  /// e.g. "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
  static let rainUserId = ""

  /// Network the assistant operates on by default. `.baseSepolia` or `.avalancheFuji`.
  static let defaultChain: WalletChain = .baseSepolia
}
