import Foundation

/// What the confirmation sheet shows before an irreversible action runs.
struct ConfirmationDetails: Sendable, Identifiable {
  let id = UUID()
  var title: String
  var fields: [Field]
  var warning: String?

  struct Field: Sendable, Identifiable {
    let id = UUID()
    var label: String
    var value: String
  }
}

/// One capability the agent can invoke: a Claude tool definition plus the Swift closure
/// that executes it against the Rain SDK.
struct AgentTool: Sendable {
  var name: String
  var description: String
  var inputSchema: JSONValue

  /// Shown in the chat while the tool runs, e.g. "Checking balances".
  var activityLabel: String

  /// Gated tools suspend the agent loop on a native confirmation sheet.
  var requiresConfirmation: Bool = false

  /// Builds the confirmation sheet content from the tool input (gated tools only).
  var confirmationSummary: (@Sendable (JSONValue) async throws -> ConfirmationDetails)? = nil

  /// Executes the tool. The returned string becomes the tool_result content.
  var run: @Sendable (JSONValue) async throws -> String

  var definition: ToolDefinition {
    ToolDefinition(name: name, description: description, inputSchema: inputSchema)
  }
}

/// Name-indexed set of tools handed to the agent loop.
struct ToolRegistry: Sendable {
  private let byName: [String: AgentTool]
  let definitions: [ToolDefinition]

  init(tools: [AgentTool]) {
    byName = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })
    definitions = tools.map(\.definition)
  }

  func tool(named name: String) -> AgentTool? {
    byName[name]
  }
}

/// Error a tool throws to surface a readable message to the model (as an is_error tool_result).
struct ToolError: Error, LocalizedError {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}
