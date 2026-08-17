import Foundation
import RainCore

/// UI hooks the loop calls as it works. All fire on the main actor.
@MainActor
protocol AgentLoopDelegate: AnyObject {
  /// A finished assistant text block (non-streaming v1 shows whole blocks).
  func agentDidProduceText(_ text: String)

  /// A tool started running; returns an activity token the loop passes to `agentToolDidFinish`.
  func agentToolDidStart(label: String) -> UUID

  func agentToolDidFinish(activity: UUID, success: Bool)

  /// Gated tool: present the confirmation sheet, suspend until the user decides.
  func agentRequestsConfirmation(_ details: ConfirmationDetails) async -> Bool
}

/// The agentic loop: Claude decides which Rain tools to call; the app executes them and feeds
/// results back until Claude produces a final answer. Runs on the main actor (every await
/// suspends, so the UI stays live).
@MainActor
final class AgentLoop {
  private let anthropic: AnthropicClient
  private let registry: ToolRegistry
  private let systemPrompt: String

  /// Full conversation state, resent on every request (the API is stateless). Assistant
  /// turns keep the response content verbatim, thinking blocks included; the API requires
  /// them to round-trip unchanged.
  private(set) var messages: [MessageParam] = []

  /// Safety valve: max assistant turns per user message.
  private let maxIterations = 8

  weak var delegate: AgentLoopDelegate?

  init(anthropic: AnthropicClient, registry: ToolRegistry, systemPrompt: String) {
    self.anthropic = anthropic
    self.registry = registry
    self.systemPrompt = systemPrompt
  }

  func send(userText: String) async throws {
    messages.append(.user(userText))

    for _ in 0..<maxIterations {
      let request = MessagesRequest(
        system: [SystemBlock(text: systemPrompt)],
        tools: registry.definitions,
        messages: messages
      )
      let response = try await anthropic.send(request)

      // Echo the assistant turn back verbatim on the next request.
      messages.append(MessageParam(role: "assistant", content: response.content))

      for block in response.content {
        if let text = block.text, !text.isEmpty {
          delegate?.agentDidProduceText(text)
        }
      }

      guard response.stopReason == "tool_use" else {
        if response.stopReason == "max_tokens" {
          delegate?.agentDidProduceText("(Response truncated by the token limit.)")
        }
        return
      }

      // One assistant turn may carry several tool_use blocks; return ALL results in a
      // single user message, in the same order.
      var results: [ContentBlock] = []
      for block in response.content {
        guard let call = block.toolUse else { continue }
        results.append(await execute(call))
      }
      messages.append(MessageParam(role: "user", content: results))
    }

    delegate?.agentDidProduceText(
      "(Stopped after \(maxIterations) steps. Ask me to continue if you'd like.)")
  }

  private func execute(
    _ call: (id: String, name: String, input: JSONValue)
  ) async -> ContentBlock {
    guard let tool = registry.tool(named: call.name) else {
      return .toolResult(
        toolUseId: call.id, content: "Unknown tool '\(call.name)'.", isError: true)
    }

    // Gated tools suspend the loop on a native confirmation sheet.
    if tool.requiresConfirmation {
      let details: ConfirmationDetails
      do {
        details =
          try await tool.confirmationSummary?(call.input)
          ?? ConfirmationDetails(title: "Confirm \(tool.name)", fields: [], warning: nil)
      } catch {
        return .toolResult(toolUseId: call.id, content: readableMessage(error), isError: true)
      }
      let approved = await delegate?.agentRequestsConfirmation(details) ?? false
      guard approved else {
        return .toolResult(
          toolUseId: call.id,
          content: "The user declined this transaction. Do not retry unless they ask again.",
          isError: false)
      }
    }

    let activity = delegate?.agentToolDidStart(label: tool.activityLabel)
    do {
      let output = try await tool.run(call.input)
      if let activity { delegate?.agentToolDidFinish(activity: activity, success: true) }
      return .toolResult(toolUseId: call.id, content: output, isError: false)
    } catch {
      if let activity { delegate?.agentToolDidFinish(activity: activity, success: false) }
      return .toolResult(toolUseId: call.id, content: readableMessage(error), isError: true)
    }
  }

  private func readableMessage(_ error: Error) -> String {
    if let sdkError = error as? RainSDKError {
      return "\(sdkError.errorCode): \(sdkError.localizedDescription)"
    }
    return error.localizedDescription
  }
}
