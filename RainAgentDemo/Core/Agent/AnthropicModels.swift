import Foundation

// MARK: - JSONValue

/// A Codable representation of arbitrary JSON, used for tool inputs, tool schemas, and
/// verbatim round-tripping of content blocks the app doesn't model (e.g. thinking blocks,
/// whose signature must be echoed back unchanged).
enum JSONValue: Codable, Equatable, Sendable {
  case string(String)
  case number(Double)
  case bool(Bool)
  case object([String: JSONValue])
  case array([JSONValue])
  case null

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([String: JSONValue].self) {
      self = .object(value)
    } else if let value = try? container.decode([JSONValue].self) {
      self = .array(value)
    } else {
      throw DecodingError.dataCorruptedError(
        in: container, debugDescription: "Unsupported JSON value")
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .string(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .bool(let value): try container.encode(value)
    case .object(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .null: try container.encodeNil()
    }
  }

  // MARK: Accessors

  subscript(key: String) -> JSONValue? {
    guard case .object(let dict) = self else { return nil }
    return dict[key]
  }

  var stringValue: String? {
    if case .string(let value) = self { return value }
    return nil
  }

  var intValue: Int? {
    if case .number(let value) = self { return Int(value) }
    return nil
  }

  var boolValue: Bool? {
    if case .bool(let value) = self { return value }
    return nil
  }

  var objectValue: [String: JSONValue]? {
    if case .object(let value) = self { return value }
    return nil
  }

  var arrayValue: [JSONValue]? {
    if case .array(let value) = self { return value }
    return nil
  }
}

// Literal conformances so tool schemas read like JSON.
extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
  ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral,
  ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral
{
  init(stringLiteral value: String) { self = .string(value) }
  init(integerLiteral value: Int) { self = .number(Double(value)) }
  init(floatLiteral value: Double) { self = .number(value) }
  init(booleanLiteral value: Bool) { self = .bool(value) }
  init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
  init(dictionaryLiteral elements: (String, JSONValue)...) {
    self = .object(Dictionary(uniqueKeysWithValues: elements))
  }
  init(nilLiteral: ()) { self = .null }
}

// MARK: - Content blocks

/// One content block in a message. Stores the raw JSON verbatim so unknown / partially
/// modeled block types (thinking blocks with signatures, future block types) round-trip
/// byte-faithfully when the conversation is sent back to the API.
struct ContentBlock: Codable, Sendable, Equatable {
  var raw: JSONValue

  init(raw: JSONValue) { self.raw = raw }

  init(from decoder: Decoder) throws {
    raw = try JSONValue(from: decoder)
  }

  func encode(to encoder: Encoder) throws {
    try raw.encode(to: encoder)
  }

  // MARK: Reads

  var type: String? { raw["type"]?.stringValue }

  /// Text of a `text` block.
  var text: String? {
    guard type == "text" else { return nil }
    return raw["text"]?.stringValue
  }

  /// Parsed `tool_use` block, if that's what this is.
  var toolUse: (id: String, name: String, input: JSONValue)? {
    guard type == "tool_use",
      let id = raw["id"]?.stringValue,
      let name = raw["name"]?.stringValue
    else { return nil }
    return (id, name, raw["input"] ?? .object([:]))
  }

  // MARK: Builders

  static func text(_ text: String) -> ContentBlock {
    ContentBlock(raw: .object(["type": "text", "text": .string(text)]))
  }

  static func toolResult(toolUseId: String, content: String, isError: Bool) -> ContentBlock {
    var fields: [String: JSONValue] = [
      "type": "tool_result",
      "tool_use_id": .string(toolUseId),
      "content": .string(content),
    ]
    if isError { fields["is_error"] = .bool(true) }
    return ContentBlock(raw: .object(fields))
  }
}

// MARK: - Messages

struct MessageParam: Codable, Sendable, Equatable {
  var role: String  // "user" | "assistant"
  var content: [ContentBlock]

  static func user(_ text: String) -> MessageParam {
    MessageParam(role: "user", content: [.text(text)])
  }
}

// MARK: - Request

struct SystemBlock: Encodable, Sendable {
  var type = "text"
  var text: String
  var cacheControl: CacheControl? = CacheControl()

  struct CacheControl: Encodable, Sendable {
    var type = "ephemeral"
  }

  enum CodingKeys: String, CodingKey {
    case type, text
    case cacheControl = "cache_control"
  }
}

struct ThinkingConfig: Encodable, Sendable {
  var type = "adaptive"
}

struct ToolDefinition: Encodable, Sendable {
  var name: String
  var description: String
  var inputSchema: JSONValue

  enum CodingKeys: String, CodingKey {
    case name, description
    case inputSchema = "input_schema"
  }
}

struct MessagesRequest: Encodable, Sendable {
  var model = "claude-opus-5"
  var maxTokens = 8192
  // Adaptive thinking; budget_tokens / temperature / top_p are removed on this model.
  // maxTokens caps thinking and response text together.
  var thinking = ThinkingConfig()
  var system: [SystemBlock]
  var tools: [ToolDefinition]
  var messages: [MessageParam]

  enum CodingKeys: String, CodingKey {
    case model, thinking, system, tools, messages
    case maxTokens = "max_tokens"
  }
}

// MARK: - Response

struct Usage: Decodable, Sendable {
  var inputTokens: Int?
  var outputTokens: Int?
  var cacheReadInputTokens: Int?
  var cacheCreationInputTokens: Int?

  enum CodingKeys: String, CodingKey {
    case inputTokens = "input_tokens"
    case outputTokens = "output_tokens"
    case cacheReadInputTokens = "cache_read_input_tokens"
    case cacheCreationInputTokens = "cache_creation_input_tokens"
  }
}

struct MessagesResponse: Decodable, Sendable {
  var id: String
  var content: [ContentBlock]
  var stopReason: String?
  var usage: Usage?

  enum CodingKeys: String, CodingKey {
    case id, content, usage
    case stopReason = "stop_reason"
  }
}

struct APIErrorEnvelope: Decodable, Sendable {
  struct Detail: Decodable, Sendable {
    var type: String
    var message: String
  }
  var error: Detail
}
