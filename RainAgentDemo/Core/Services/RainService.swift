import Foundation
import RainCore
import RainPrivy
import PrivySDK
import TurnkeySwift

/// Wallet provider the demo can sign with. Both are registered the same way — a descriptor on the
/// `RainSdk` builder — and resolve to the same `RainClient` surface.
enum WalletProviderKind: String, CaseIterable, Identifiable, Sendable {
  case privy
  case turnkey

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .privy: return "Privy"
    case .turnkey: return "Turnkey"
    }
  }

  /// The SDK-side id this provider resolves under.
  var providerId: ProviderId {
    switch self {
    case .privy: return .privy
    case .turnkey: return .turnkey
    }
  }
}

/// Builds the Rain SDK with the selected wallet provider and exposes the resolved client to the
/// agent layer. Privy and Turnkey only; money stays Decimal end to end.
@MainActor
final class RainService: ObservableObject {
  static let shared = RainService()

  /// The built SDK registry (Rain issuing API + wallet-agnostic helpers).
  private var rain: RainSdk?

  /// The provider-backed client (address, balances, send, withdraw).
  private var client: RainClient?

  @Published var isInitialized = false
  @Published var selectedChain: WalletChain = AgentLocalConfig.defaultChain

  /// Provider behind the last successful initialize; nil before one runs.
  @Published private(set) var activeProvider: WalletProviderKind?

  /// Wallet address cached at init so the UI and system prompt can read it synchronously.
  @Published var walletAddress: String = ""

  /// Chains the built SDK will actually accept an Auth Pull approval on: the configured
  /// operator/token map narrowed to chains that have an RPC endpoint. Empty means the feature is
  /// off for this build, and its tools are not registered.
  @Published private(set) var authPullChainIds: Set<Int> = []

  private init() {}

  /// Builds the SDK against an authenticated Privy singleton and resolves the client.
  func initialize(privy: any Privy) async throws {
    try await build(.privy) { builder in
      builder.register(PrivyProvider(PrivyConfig(privy: privy, walletAddress: nil)))
    }
  }

  /// Builds the SDK against an authenticated Turnkey context and resolves the client.
  func initialize(turnkey: TurnkeyContext) async throws {
    try await build(.turnkey) { builder in
      builder.register(TurnkeyProvider(RainCore.TurnkeyConfig(turnkey: turnkey, walletAddress: nil)))
    }
  }

  /// The resolved provider client, or throws when not initialized.
  func requireClient() throws -> RainClient {
    guard let client else { throw RainSDKError.sdkNotInitialized }
    return client
  }

  /// The built registry (for Rain issuing API calls), or throws when not initialized.
  func requireRain() throws -> RainSdk {
    guard let rain else { throw RainSDKError.sdkNotInitialized }
    return rain
  }

  /// Drops the built SDK and resolved client (e.g. on logout).
  func reset() {
    client?.reset()
    rain?.reset()
    rain = nil
    client = nil
    authPullChainIds = []
    walletAddress = ""
    activeProvider = nil
    isInitialized = false
  }

  // MARK: - Building

  /// Shared builder setup, then resolve the provider's client and cache its address.
  private func build(
    _ kind: WalletProviderKind,
    register: (RainSdk.Builder) -> Void
  ) async throws {
    RainLogger.isEnabled = true

    let builder = RainSdk.builder()
      .rpcEndpoints(WalletChain.networkConfigs)
      // Neither provider exposes a testnet token index, so balance reads only see tokens the
      // SDK already knows about. The built-in registry is mainnet-only; seed each testnet's
      // USDC so it shows up in balances.
      .registerTokens(WalletChain.allCases.map(\.usdcTokenInfo))
      .rainApiEnvironment(.dev)
    // Auth Pull is refused entirely without this, and then accepts only this operator and the
    // canonical USDC contract per chain. Sandbox targets, to match .dev above.
    if !AgentLocalConfig.rainAuthPullOperator.isEmpty {
      builder.authPullConfig(.sandbox(operatorAddress: AgentLocalConfig.rainAuthPullOperator))
    }
    register(builder)

    if !AgentLocalConfig.rainApiKey.isEmpty, !AgentLocalConfig.rainUserId.isEmpty {
      builder.rainApiCredentials(
        apiKey: AgentLocalConfig.rainApiKey,
        userId: AgentLocalConfig.rainUserId
      )
    }

    let sdk = try builder.build()
    let resolvedClient = try await sdk.provider(kind.providerId)

    // Fetch the wallet address to prove the provider resolved a usable wallet.
    let address = try await resolvedClient.getWalletAddress()

    rain = sdk
    client = resolvedClient
    authPullChainIds = sdk.authPullChainIds
    walletAddress = address
    activeProvider = kind
    isInitialized = resolvedClient.isInitialized
  }
}
