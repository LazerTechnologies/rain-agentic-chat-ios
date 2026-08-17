import SwiftUI

@main
struct RainAgentDemoApp: App {
  @StateObject private var appState = AppState()

  var body: some Scene {
    WindowGroup {
      RootView()
        .environmentObject(appState)
        .task { await appState.bootstrap() }
    }
  }
}

/// Top-level routing: login until the wallet provider + Rain SDK are ready, then chat.
@MainActor
final class AppState: ObservableObject {
  enum Phase {
    case launching
    case login
    case connecting
    case chat
  }

  @Published var phase: Phase = .launching
  @Published var bootError: String?

  /// Wallet provider the login screen signs in with.
  @Published var provider: WalletProviderKind = .privy

  let rainService = RainService.shared
  let privyAuth = PrivyAuthService.shared
  let turnkeyAuth = TurnkeyAuthService.shared

  /// On launch: init both providers' SDKs and resume whichever has a live session.
  func bootstrap() async {
    if privyAuth.isAvailable {
      privyAuth.initialize(
        appId: AgentLocalConfig.privyAppId,
        appClientId: AgentLocalConfig.privyAppClientId
      )
    }
    // Turnkey restores a session from the Keychain, but only once its singleton is configured.
    _ = try? turnkeyAuth.configure()

    if await privyAuth.hasActiveSession() {
      provider = .privy
      await connect()
    } else if await turnkeyAuth.awaitRestoredSession() {
      provider = .turnkey
      await connect()
    } else {
      // Preselect a provider the config can actually sign in with.
      provider = privyAuth.isAvailable || !turnkeyAuth.isAvailable ? .privy : .turnkey
      phase = .login
    }
  }

  /// Post-auth: ensure the provider's wallet exists and build the Rain SDK against it.
  func connect() async {
    phase = .connecting
    bootError = nil
    do {
      switch provider {
      case .privy:
        try await privyAuth.ensureEthereumWallet()
        try await rainService.initialize(privy: privyAuth.privy)
      case .turnkey:
        try await turnkeyAuth.ensureEthereumWallet()
        try await rainService.initialize(turnkey: turnkeyAuth.context)
      }
      phase = .chat
    } catch {
      bootError = error.localizedDescription
      phase = .login
    }
  }

  func logout() async {
    switch provider {
    case .privy: await privyAuth.logout()
    case .turnkey: turnkeyAuth.logout()
    }
    rainService.reset()
    phase = .login
  }
}

struct RootView: View {
  @EnvironmentObject private var appState: AppState

  var body: some View {
    switch appState.phase {
    case .launching:
      ProgressView("Starting…")
    case .login, .connecting:
      LoginView()
    case .chat:
      ChatView()
    }
  }
}
