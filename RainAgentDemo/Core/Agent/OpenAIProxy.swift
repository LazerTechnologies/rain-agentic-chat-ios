import Foundation

/// Translation layer for OpenAI-format Claude proxies (`POST /v1/chat/completions`).
///
/// The app speaks the Anthropic Messages format internally (AgentLoop, tool registry,
/// transcript state all use `MessagesRequest`/`MessagesResponse`). When a proxy that only
/// exposes the OpenAI chat-completions wire format is configured, `AnthropicClient`
/// converts the request here on the way out and the response back on the way in, so the
/// rest of the app is unaware of the proxy. Thinking blocks are dropped on translation
/// (the OpenAI format has no equivalent to round-trip).

// MARK: - Request

struct OpenAIChatRequest: Encodable, Sendable {
  var model: String
  var maxTokens: Int
  var messages: [OpenAIChatMessage]
  var tools: [OpenAITool]?

  enum CodingKeys: String, CodingKey {
    case model, messages, tools
    case maxTokens = "max_tokens"
  }

  init(from request: MessagesRequest, model: String) {
    self.model = model
    maxTokens = request.maxTokens

    var out: [OpenAIChatMessage] = []
    let systemText = request.system.map(\.text).joined(separator: "\n\n")
    if !systemText.isEmpty {
      out.append(OpenAIChatMessage(role: "system", content: systemText))
    }

    for message in request.messages {
      if message.role == "assistant" {
        var text = ""
        var calls: [OpenAIToolCall] = []
        for block in message.content {
          if let blockText = block.text, !blockText.isEmpty {
            text += (text.isEmpty ? "" : "\n") + blockText
          }
          if let call = block.toolUse {
            calls.append(
              OpenAIToolCall(
                id: call.id,
                function: .init(name: call.name, arguments: Self.jsonString(call.input))
              ))
          }
        }
        out.append(
          OpenAIChatMessage(
            role: "assistant",
            content: text.isEmpty ? nil : text,
            toolCalls: calls.isEmpty ? nil : calls
          ))
      } else {
        // A user turn: tool_result blocks become individual `tool` role messages
        // (they must directly follow the assistant message carrying the tool_calls);
        // plain text blocks become a normal user message.
        var text = ""
        for block in message.content {
          if block.type == "tool_result" {
            out.append(
              OpenAIChatMessage(
                role: "tool",
                content: block.raw["content"]?.stringValue ?? "",
                toolCallId: block.raw["tool_use_id"]?.stringValue
              ))
          } else if let blockText = block.text, !blockText.isEmpty {
            text += (text.isEmpty ? "" : "\n") + blockText
          }
        }
        if !text.isEmpty {
          out.append(OpenAIChatMessage(role: "user", content: text))
        }
      }
    }
    messages = out

    tools =
      request.tools.isEmpty
      ? nil
      : request.tools.map {
        OpenAITool(
          function: .init(name: $0.name, description: $0.description, parameters: $0.inputSchema))
      }
  }

  private static func jsonString(_ value: JSONValue) -> String {
    guard let data = try? JSONEncoder().encode(value),
      let string = String(data: data, encoding: .utf8)
    else { return "{}" }
    return string
  }
}

struct OpenAIChatMessage: Encodable, Sendable {
  var role: String
  var content: String?
  var toolCalls: [OpenAIToolCall]?
  var toolCallId: String?

  enum CodingKeys: String, CodingKey {
    case role, content
    case toolCalls = "tool_calls"
    case toolCallId = "tool_call_id"
  }
}

struct OpenAIToolCall: Codable, Sendable {
  var id: String
  var type = "function"
  var function: FunctionCall

  struct FunctionCall: Codable, Sendable {
    var name: String
    var arguments: String  // JSON-encoded object
  }
}

struct OpenAITool: Encodable, Sendable {
  var type = "function"
  var function: FunctionDefinition

  struct FunctionDefinition: Encodable, Sendable {
    var name: String
    var description: String
    var parameters: JSONValue
  }
}

// MARK: - Response

struct OpenAIChatResponse: Decodable, Sendable {
  var id: String?
  var choices: [Choice]
  var usage: OpenAIUsage?

  struct Choice: Decodable, Sendable {
    var message: ChoiceMessage
    var finishReason: String?

    enum CodingKeys: String, CodingKey {
      case message
      case finishReason = "finish_reason"
    }
  }

  struct ChoiceMessage: Decodable, Sendable {
    var content: String?
    var toolCalls: [OpenAIToolCall]?

    enum CodingKeys: String, CodingKey {
      case content
      case toolCalls = "tool_calls"
    }
  }

  struct OpenAIUsage: Decodable, Sendable {
    var promptTokens: Int?
    var completionTokens: Int?

    enum CodingKeys: String, CodingKey {
      case promptTokens = "prompt_tokens"
      case completionTokens = "completion_tokens"
    }
  }

  /// Converts back to the Anthropic shape the rest of the app consumes.
  func toMessagesResponse() -> MessagesResponse {
    var blocks: [ContentBlock] = []
    let message = choices.first?.message

    if let text = message?.content, !text.isEmpty {
      blocks.append(.text(text))
    }
    for call in message?.toolCalls ?? [] {
      let input: JSONValue =
        (try? JSONDecoder().decode(JSONValue.self, from: Data(call.function.arguments.utf8)))
        ?? .object([:])
      blocks.append(
        ContentBlock(
          raw: .object([
            "type": "tool_use",
            "id": .string(call.id),
            "name": .string(call.function.name),
            "input": input,
          ])))
    }

    let stopReason: String
    switch choices.first?.finishReason {
    case "tool_calls": stopReason = "tool_use"
    case "length": stopReason = "max_tokens"
    default: stopReason = "end_turn"
    }

    return MessagesResponse(
      id: id ?? UUID().uuidString,
      content: blocks,
      stopReason: stopReason,
      usage: Usage(
        inputTokens: usage?.promptTokens,
        outputTokens: usage?.completionTokens,
        cacheReadInputTokens: nil,
        cacheCreationInputTokens: nil
      )
    )
  }
}
