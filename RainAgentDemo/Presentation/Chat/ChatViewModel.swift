import Foundation
import SwiftUI

/// One entry in the chat transcript.
struct ChatMessage: Identifiable {
  enum Kind {
    case user(String)
    case assistant(String)
    case toolActivity(label: String, state: ToolActivityState)
    case approval(details: ConfirmationDetails, state: ApprovalState)
    case error(String)
  }

  let id: UUID
  var kind: Kind

  init(id: UUID = UUID(), kind: Kind) {
    self.id = id
    self.kind = kind
  }
}

enum ToolActivityState {
  case running
  case done
  case failed
}

enum ApprovalState {
  case pending
  case approved
  case declined
}

/// A gated tool call waiting on the user's decision. Wraps the continuation the agent loop
/// is suspended on; guarded so it resumes exactly once (swipe-dismiss counts as decline).
@MainActor
final class PendingConfirmation: Identifiable {
  let id = UUID()
  let details: ConfirmationDetails
  private var continuation: CheckedContinuation<Bool, Never>?

  init(details: ConfirmationDetails, continuation: CheckedContinuation<Bool, Never>) {
    self.details = details
    self.continuation = continuation
  }

  func resolve(approved: Bool) {
    continuation?.resume(returning: approved)
    continuation = nil
  }
}

@MainActor
final class ChatViewModel: ObservableObject, AgentLoopDelegate {
  @Published var messages: [ChatMessage] = []
  @Published var isRunning = false
  @Published var pendingConfirmation: PendingConfirmation?
  private var pendingApprovalMessageID: UUID?

  let walletAddress: String
  let chain: WalletChain

  /// Provider backing the resolved client, for the account menu and the system prompt.
  let provider: WalletProviderKind?

  private var loop: AgentLoop?

  static let suggestedPrompts = [
    "What's in my wallet?",
    "Analyze my recent spending",
    "What's backing my Rain card?",
  ]

  init() {
    let rainService = RainService.shared
    walletAddress = rainService.walletAddress
    chain = rainService.selectedChain
    provider = rainService.activeProvider

    if let client = try? rainService.requireClient(),
      let rain = try? rainService.requireRain()
    {
      let tools = makeRainTools(
        client: client,
        rain: rain,
        walletAddress: walletAddress,
        defaultChain: chain
      )
      let usesProxy = !AgentLocalConfig.claudeProxyBaseURL.isEmpty
      let loop = AgentLoop(
        anthropic: AnthropicClient(
          apiKey: usesProxy ? AgentLocalConfig.claudeProxyToken : AgentLocalConfig.anthropicAPIKey,
          proxyBaseURL: AgentLocalConfig.claudeProxyBaseURL,
          proxyModel: AgentLocalConfig.claudeProxyModel
        ),
        registry: ToolRegistry(tools: tools),
        systemPrompt: SystemPrompt.build(
          walletAddress: walletAddress,
          defaultChain: chain,
          provider: rainService.activeProvider
        )
      )
      loop.delegate = self
      self.loop = loop
    } else {
      messages.append(
        ChatMessage(kind: .error("Wallet not connected. Log in again to start chatting.")))
    }
  }

  var shortAddress: String {
    guard walletAddress.count > 12 else { return walletAddress }
    return "\(walletAddress.prefix(6))…\(walletAddress.suffix(4))"
  }

  func send(_ text: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !isRunning, let loop else { return }

    messages.append(ChatMessage(kind: .user(trimmed)))
    isRunning = true

    Task {
      do {
        try await loop.send(userText: trimmed)
      } catch {
        messages.append(ChatMessage(kind: .error(error.localizedDescription)))
      }
      isRunning = false
    }
  }

  // MARK: - AgentLoopDelegate

  func agentDidProduceText(_ text: String) {
    messages.append(ChatMessage(kind: .assistant(text)))
  }

  func agentToolDidStart(label: String) -> UUID {
    let message = ChatMessage(kind: .toolActivity(label: label, state: .running))
    messages.append(message)
    return message.id
  }

  func agentToolDidFinish(activity: UUID, success: Bool) {
    guard let index = messages.firstIndex(where: { $0.id == activity }),
      case .toolActivity(let label, _) = messages[index].kind
    else { return }
    messages[index].kind = .toolActivity(label: label, state: success ? .done : .failed)
  }

  func agentRequestsConfirmation(_ details: ConfirmationDetails) async -> Bool {
    await withCheckedContinuation { continuation in
      let card = ChatMessage(kind: .approval(details: details, state: .pending))
      messages.append(card)
      pendingApprovalMessageID = card.id
      pendingConfirmation = PendingConfirmation(details: details, continuation: continuation)
    }
  }

  /// Called by the approval card's buttons. Resumes the suspended agent loop and
  /// freezes the card into an approved/declined record in the transcript.
  func resolveConfirmation(approved: Bool) {
    if let id = pendingApprovalMessageID,
      let index = messages.firstIndex(where: { $0.id == id }),
      case .approval(let details, _) = messages[index].kind
    {
      messages[index].kind = .approval(details: details, state: approved ? .approved : .declined)
    }
    pendingApprovalMessageID = nil
    pendingConfirmation?.resolve(approved: approved)
    pendingConfirmation = nil
  }
}
