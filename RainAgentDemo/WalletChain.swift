import Foundation
import RainCore

/// The EVM networks the demo operates on. The SDK is initialized with every entry's RPC
/// endpoint at once, so switching networks needs no re-init.
enum WalletChain: String, CaseIterable, Identifiable, Sendable {
  case baseSepolia
  case avalancheFuji

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .avalancheFuji: return "Avalanche Fuji"
    case .baseSepolia: return "Base Sepolia"
    }
  }

  var chainId: Int {
    switch self {
    case .avalancheFuji: return RainChain.avalancheTestnet
    case .baseSepolia: return 84532
    }
  }

  var rpcUrl: String {
    switch self {
    case .avalancheFuji: return "https://api.avax-test.network/ext/bc/C/rpc"
    case .baseSepolia: return "https://sepolia.base.org"
    }
  }

  var nativeSymbol: String {
    switch self {
    case .avalancheFuji: return "AVAX"
    case .baseSepolia: return "ETH"
    }
  }

  /// Block-explorer name, e.g. for a "View on Basescan" label.
  var explorerName: String {
    switch self {
    case .avalancheFuji: return "Snowtrace"
    case .baseSepolia: return "Basescan"
    }
  }

  private var explorerBase: String {
    switch self {
    case .avalancheFuji: return "https://testnet.snowtrace.io"
    case .baseSepolia: return "https://sepolia.basescan.org"
    }
  }

  func explorerTxURL(hash: String) -> URL? {
    URL(string: "\(explorerBase)/tx/\(hash)")
  }

  func explorerAddressURL(address: String) -> URL? {
    URL(string: "\(explorerBase)/address/\(address)")
  }

  /// USDC on this testnet, registered with the SDK at init so discovered holdings carry a
  /// symbol and decimals instead of just a contract address.
  var usdcTokenInfo: TokenInfo {
    switch self {
    case .avalancheFuji:
      return TokenInfo(
        chainId: chainId,
        address: "0x5425890298aed601595a70AB815c96711a31Bc65",
        symbol: "USDC",
        decimals: 6,
        name: "USDC"
      )
    case .baseSepolia:
      return TokenInfo(
        chainId: chainId,
        address: "0x036CbD53842c5426634e7929541eC2318f3dCF7e",
        symbol: "USDC",
        decimals: 6,
        name: "USDC"
      )
    }
  }

  /// Light client-side address sanity check (the SDK validates authoritatively).
  func isValidAddress(_ address: String) -> Bool {
    address.hasPrefix("0x")
      && address.count == 42
      && address.dropFirst(2).allSatisfy { $0.isHexDigit }
  }

  /// Every chain's NetworkConfig, for initializing the SDK with all chains at once.
  static var networkConfigs: [NetworkConfig] {
    allCases.map {
      NetworkConfig(chainId: $0.chainId, rpcUrl: $0.rpcUrl, networkName: $0.displayName)
    }
  }

  static func from(chainId: Int) -> WalletChain? {
    allCases.first { $0.chainId == chainId }
  }
}
