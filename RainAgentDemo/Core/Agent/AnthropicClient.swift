import Foundation

/// Errors surfaced by the Anthropic Messages API client.
enum AnthropicError: Error, LocalizedError {
  case missingAPIKey
  case rateLimited(retryAfterSeconds: Int)
  case overloaded
  case api(status: Int, type: String, message: String)
  case network(underlying: Error)
  case decoding(underlying: Error)

  var errorDescription: String? {
    switch self {
    case .missingAPIKey:
      return "No Anthropic API key or Claude proxy token configured. Fill in AgentLocalConfig.swift."
    case .rateLimited(let seconds):
      return "Rate limited by the Anthropic API. Retry in \(seconds)s."
    case .overloaded:
      return "The Anthropic API is temporarily overloaded. Try again shortly."
    case .api(let status, let type, let message):
      return "Anthropic API error \(status) (\(type)): \(message)"
    case .network(let underlying):
      return "Network error: \(underlying.localizedDescription)"
    case .decoding(let underlying):
      return "Failed to decode API response: \(underlying.localizedDescription)"
    }
  }
}

/// Minimal raw-HTTPS client for `POST /v1/messages`.
///
/// There is no official Anthropic Swift SDK, so this speaks the wire format directly.
/// Demo scope: non-streaming, one automatic retry on 429/5xx/529.
final class AnthropicClient: Sendable {
  private let apiKey: String
  private let usesProxy: Bool
  private let proxyModel: String
  private let session: URLSession
  private let endpoint: URL

  /// Direct Anthropic (`proxyBaseURL` empty) or an OpenAI-format Claude proxy at
  /// `<proxyBaseURL>/v1/chat/completions` (see OpenAIProxy.swift for the translation).
  /// With a proxy, `apiKey` is the proxy token, sent as both `Authorization: Bearer`
  /// and `x-api-key` to cover either auth style, and `proxyModel` is the proxy's own
  /// model id (e.g. "claude-opus-4.8"), which overrides the request's model.
  init(apiKey: String, proxyBaseURL: String = "", proxyModel: String = "") {
    self.apiKey = apiKey
    self.proxyModel = proxyModel
    let trimmed = proxyBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    usesProxy = !trimmed.isEmpty
    if usesProxy {
      let base = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
      endpoint = URL(
        string: base.hasSuffix("/v1/chat/completions") ? base : base + "/v1/chat/completions")!
    } else {
      endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    }
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 300
    session = URLSession(configuration: config)
  }

  func send(_ request: MessagesRequest) async throws -> MessagesResponse {
    guard !apiKey.isEmpty else { throw AnthropicError.missingAPIKey }

    do {
      return try await sendOnce(request)
    } catch let error as AnthropicError {
      // One retry with backoff for transient failures.
      switch error {
      case .rateLimited(let seconds):
        try await Task.sleep(for: .seconds(min(seconds, 20)))
        return try await sendOnce(request)
      case .overloaded:
        try await Task.sleep(for: .seconds(2))
        return try await sendOnce(request)
      case .api(let status, _, _) where status >= 500:
        try await Task.sleep(for: .seconds(2))
        return try await sendOnce(request)
      default:
        throw error
      }
    }
  }

  private func sendOnce(_ request: MessagesRequest) async throws -> MessagesResponse {
    var urlRequest = URLRequest(url: endpoint)
    urlRequest.httpMethod = "POST"
    urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
    if usesProxy {
      urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    }
    urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if usesProxy {
      urlRequest.httpBody = try JSONEncoder().encode(
        OpenAIChatRequest(from: request, model: proxyModel))
    } else {
      urlRequest.httpBody = try JSONEncoder().encode(request)
    }

    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.data(for: urlRequest)
    } catch {
      throw AnthropicError.network(underlying: error)
    }

    guard let http = response as? HTTPURLResponse else {
      throw AnthropicError.network(underlying: URLError(.badServerResponse))
    }

    guard (200..<300).contains(http.statusCode) else {
      let envelope = try? JSONDecoder().decode(APIErrorEnvelope.self, from: data)
      switch http.statusCode {
      case 429:
        let retryAfter = Int(http.value(forHTTPHeaderField: "retry-after") ?? "") ?? 10
        throw AnthropicError.rateLimited(retryAfterSeconds: retryAfter)
      case 529:
        throw AnthropicError.overloaded
      default:
        throw AnthropicError.api(
          status: http.statusCode,
          type: envelope?.error.type ?? "unknown",
          message: envelope?.error.message ?? String(data: data, encoding: .utf8) ?? ""
        )
      }
    }

    do {
      if usesProxy {
        return try JSONDecoder().decode(OpenAIChatResponse.self, from: data).toMessagesResponse()
      }
      return try JSONDecoder().decode(MessagesResponse.self, from: data)
    } catch {
      throw AnthropicError.decoding(underlying: error)
    }
  }
}
