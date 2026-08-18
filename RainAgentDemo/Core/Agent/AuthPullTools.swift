import Foundation
import BigInt
import RainCore

/// Auth Pull tools: the wallet-side allowance that lets a Rain card authorization pull USDC from
/// this wallet into the user's collateral contract. The SDK sets and reads the allowance; Rain
/// performs the pull itself, server-side.
///
/// Registered only when the built SDK actually accepts approvals (`authPullChainIds` is the
/// configured operator/token map narrowed to chains that have an RPC endpoint). With no
/// `authPullConfig` the tools are absent rather than failing at call time, so the model never
/// offers a capability this build cannot perform.
func makeAuthPullTools(
  client: RainClient,
  defaultChain: WalletChain
) -> [AgentTool] {
  let enabledChainIds = client.authPullChainIds
  let operatorAddress = AgentLocalConfig.rainAuthPullOperator
  guard !enabledChainIds.isEmpty, !operatorAddress.isEmpty else { return [] }

  let enabledChains = WalletChain.allCases.filter { enabledChainIds.contains($0.chainId) }
  guard let fallbackChain = enabledChains.first else { return [] }
  let preferredChain = enabledChains.contains(defaultChain) ? defaultChain : fallbackChain
  let chainNames = enabledChains.map(\.displayName).joined(separator: ", ")

  // The chain enum for these tools lists only Auth Pull chains, so the model cannot propose a
  // network the SDK will reject.
  let authPullChainProperty: JSONValue = .object([
    "type": "string",
    "enum": .array(enabledChains.map { .string($0.rawValue) }),
    "description": .string("Auth Pull network. Defaults to \(preferredChain.rawValue)."),
  ])

  @Sendable func resolveAuthPullChain(_ input: JSONValue) throws -> WalletChain {
    let chain = try resolveChain(input, default: preferredChain)
    guard enabledChainIds.contains(chain.chainId) else {
      throw ToolError(
        "Auth Pull is not available on \(chain.displayName). Enabled networks: \(chainNames).")
    }
    return chain
  }

  /// USDC on the chain, which is also the only token the SDK will let an approval target.
  @Sendable func authPullToken(_ chain: WalletChain) -> TokenInfo { chain.usdcTokenInfo }

  /// `nil` means unlimited — an omitted amount, or an explicit "unlimited".
  @Sendable func approvalAmount(_ input: JSONValue) throws -> Decimal? {
    guard let raw = input["amount"]?.stringValue?
      .trimmingCharacters(in: .whitespaces), !raw.isEmpty
    else { return nil }
    if raw.caseInsensitiveCompare("unlimited") == .orderedSame { return nil }
    if let value = Decimal(string: raw), value == 0 {
      throw ToolError("An amount of 0 means revoking; use revoke_auth_pull for that.")
    }
    return try AmountMath.parseAmount(raw)
  }

  @Sendable func allowanceJSON(_ allowance: RainTokenAllowance) -> JSONValue {
    .object([
      // rawAmount is the exact value to compare against; `formatted` rounds past 38 significant
      // digits, so an unlimited allowance formats as a meaningless 72-digit figure.
      "raw_amount": .string(allowance.rawAmount.description),
      "formatted": .string(allowance.isUnlimited ? "unlimited" : allowance.formatted),
      "decimals": .number(Double(allowance.decimals)),
      "is_unlimited": .bool(allowance.isUnlimited),
      "is_zero": .bool(allowance.isZero),
    ])
  }

  @Sendable func targetJSON(chain: WalletChain, token: TokenInfo) -> [String: JSONValue] {
    [
      "chain": .string(chain.displayName),
      "chain_id": .number(Double(chain.chainId)),
      "token": .string(token.symbol ?? "USDC"),
      "token_address": .string(token.address),
      "operator_address": .string(operatorAddress),
    ]
  }

  // MARK: get_auth_pull_status

  let getAuthPullStatus = AgentTool(
    name: "get_auth_pull_status",
    description:
      "Check whether this wallet is set up for Auth Pull: the USDC allowance Rain's operator holds, "
      + "plus the USDC and gas balances a pull and an approval need. Free and read-only. Call this "
      + "before approving, so an already-approved wallet does not pay for a redundant transaction, "
      + "and whenever the user asks why a card authorization was declined.",
    inputSchema: objectSchema([
      "chain": authPullChainProperty,
      "amount": .object([
        "type": "string",
        "description":
          "Optional USDC amount to test the allowance against, e.g. \"25\". Adds `covers`.",
      ]),
    ]),
    activityLabel: "Checking Auth Pull status"
  ) { input in
    let chain = try resolveAuthPullChain(input)
    let token = authPullToken(chain)
    let allowance = try await client.getTokenAllowance(
      chainId: chain.chainId,
      contractAddress: token.address,
      spender: operatorAddress
    )

    // A balance read failing must not sink the allowance answer; report the gap instead of
    // inferring "no USDC" from a network error.
    let balances = try? await client.getTokenBalances(chainId: chain.chainId)

    var fields = targetJSON(chain: chain, token: token)
    fields["owner"] = .string(allowance.owner)
    fields["allowance"] = allowanceJSON(allowance)

    var blockers: [JSONValue] = []
    if allowance.isZero {
      blockers.append(
        .string(
          "No allowance: Rain's operator cannot pull \(token.symbol ?? "USDC") yet. "
            + "Approving is what enables Auth Pull."))
    }
    if let balances {
      let usdc = balances.first {
        if case .contract(let address) = $0.token {
          return address.caseInsensitiveCompare(token.address) == .orderedSame
        }
        return false
      }
      let native = balances.first { if case .native = $0.token { return true } else { return false } }
      fields["usdc_balance"] = .string(usdc?.formatted ?? "0")
      fields["native_balance"] = .string(native?.formatted ?? "0")
      fields["native_symbol"] = .string(chain.nativeSymbol)
      if (usdc?.rawAmount ?? 0) == 0 {
        blockers.append(
          .string(
            "Wallet holds no \(token.symbol ?? "USDC") on \(chain.displayName), so there is nothing "
              + "for an authorization to pull even with an allowance in place."))
      }
      if allowance.isZero, (native?.rawAmount ?? 0) == 0 {
        blockers.append(
          .string("No \(chain.nativeSymbol) for gas, so the approval transaction cannot be submitted."))
      }
    } else {
      fields["balances_unavailable"] = .bool(true)
    }

    if let raw = input["amount"]?.stringValue, !raw.isEmpty {
      let amount = try AmountMath.parseAmount(raw)
      fields["requested_amount"] = .string("\(amount)")
      fields["covers"] = .bool(allowance.covers(amount))
    }

    fields["ready"] = .bool(blockers.isEmpty)
    fields["blockers"] = .array(blockers)
    return jsonString(.object(fields))
  }

  // MARK: estimate_auth_pull_fee

  let estimateAuthPullFee = AgentTool(
    name: "estimate_auth_pull_fee",
    description:
      "Estimate the network fee for the Auth Pull approval transaction, in the chain's native gas "
      + "token. Nothing is broadcast and the user is not prompted.",
    inputSchema: objectSchema([
      "chain": authPullChainProperty,
      "amount": .object([
        "type": "string",
        "description":
          "USDC allowance the estimate prices, e.g. \"250\". Omit for an unlimited approval.",
      ]),
    ]),
    activityLabel: "Estimating approval fee"
  ) { input in
    let chain = try resolveAuthPullChain(input)
    let token = authPullToken(chain)
    let amount = try approvalAmount(input)
    let fee = try await client.estimateApprovalFee(
      chainId: chain.chainId,
      contractAddress: token.address,
      spender: operatorAddress,
      amount: amount
    )
    var fields = targetJSON(chain: chain, token: token)
    fields["estimated_fee"] = .string("\(fee)")
    fields["fee_token"] = .string(chain.nativeSymbol)
    fields["allowance"] = .string(amount.map { "\($0)" } ?? "unlimited")
    return jsonString(.object(fields))
  }

  // MARK: approve_auth_pull

  let approveAuthPull = AgentTool(
    name: "approve_auth_pull",
    description:
      "Approve Rain's operator to move USDC from this wallet, which is what lets a card "
      + "authorization pull collateral. Omit `amount` for an unlimited allowance (what Rain "
      + "recommends, so the user never has to re-approve); pass an amount to cap it. Submits an "
      + "on-chain transaction and costs gas; the app shows the user a confirmation sheet first. "
      + "Follow up with confirm_auth_pull before telling the user they are ready.",
    inputSchema: objectSchema([
      "chain": authPullChainProperty,
      "amount": .object([
        "type": "string",
        "description": .string(
          "Maximum USDC the operator may move, as a decimal string, e.g. \"250\". Omit for "
          + "unlimited. A capped allowance is a standing balance that each pull spends down, not a "
          + "per-authorization budget."),
      ]),
    ]),
    activityLabel: "Approving Auth Pull",
    requiresConfirmation: true,
    confirmationSummary: { input in
      let chain = try resolveAuthPullChain(input)
      let token = authPullToken(chain)
      let symbol = token.symbol ?? "USDC"
      let amount = try approvalAmount(input)
      let cap = amount.map { "\($0) \(symbol)" }
      return ConfirmationDetails(
        title: "Approve \(cap ?? "unlimited \(symbol)")",
        fields: [
          .init(label: "Allowance", value: cap ?? "Unlimited \(symbol)"),
          .init(label: "Spender", value: "Rain operator \(operatorAddress)"),
          .init(label: "Token", value: "\(symbol) \(token.address)"),
          .init(label: "Network", value: chain.displayName),
        ],
        warning: cap.map { "Rain's operator will be able to move up to \($0) from this wallet." }
          ?? "Rain's operator will be able to move any amount of \(symbol) from this wallet until "
            + "the allowance is revoked."
      )
    }
  ) { input in
    let chain = try resolveAuthPullChain(input)
    let token = authPullToken(chain)
    let amount = try approvalAmount(input)
    let result = try await client.approveTokenAllowance(
      chainId: chain.chainId,
      contractAddress: token.address,
      spender: operatorAddress,
      amount: amount
    )
    var fields = targetJSON(chain: chain, token: token)
    fields["status"] = "submitted"
    fields["transaction_hash"] = .string(result.transactionHash)
    fields["explorer_url"] = .string(chain.explorerTxURL(hash: result.transactionHash)?.absoluteString ?? "")
    fields["approved_amount"] = .string(amount.map { "\($0)" } ?? "unlimited")
    fields["next_step"] = .string(
      "Submitted, not yet mined. Call confirm_auth_pull with this transaction_hash and "
        + "amount=\"\(amount.map { "\($0)" } ?? "unlimited")\".")
    return jsonString(.object(fields))
  }

  // MARK: revoke_auth_pull

  let revokeAuthPull = AgentTool(
    name: "revoke_auth_pull",
    description:
      "Revoke Rain's USDC allowance on this wallet by setting it to zero. Auth Pull card "
      + "authorizations are declined afterwards until the user approves again. Submits an on-chain "
      + "transaction and costs gas; the app shows the user a confirmation sheet first.",
    inputSchema: objectSchema(["chain": authPullChainProperty]),
    activityLabel: "Revoking Auth Pull allowance",
    requiresConfirmation: true,
    confirmationSummary: { input in
      let chain = try resolveAuthPullChain(input)
      let token = authPullToken(chain)
      let symbol = token.symbol ?? "USDC"
      return ConfirmationDetails(
        title: "Revoke Rain's \(symbol) allowance",
        fields: [
          .init(label: "New allowance", value: "0 \(symbol)"),
          .init(label: "Spender", value: "Rain operator \(operatorAddress)"),
          .init(label: "Network", value: chain.displayName),
        ],
        warning:
          "Card authorizations that rely on Auth Pull will be declined until a new approval is made."
      )
    }
  ) { input in
    let chain = try resolveAuthPullChain(input)
    let token = authPullToken(chain)
    let result = try await client.approveTokenAllowance(
      chainId: chain.chainId,
      contractAddress: token.address,
      spender: operatorAddress,
      amount: 0
    )
    var fields = targetJSON(chain: chain, token: token)
    fields["status"] = "submitted"
    fields["transaction_hash"] = .string(result.transactionHash)
    fields["explorer_url"] = .string(chain.explorerTxURL(hash: result.transactionHash)?.absoluteString ?? "")
    fields["approved_amount"] = "0"
    fields["next_step"] = .string(
      "Submitted, not yet mined. Call confirm_auth_pull with this transaction_hash and amount=\"0\".")
    return jsonString(.object(fields))
  }

  // MARK: confirm_auth_pull

  let confirmAuthPull = AgentTool(
    name: "confirm_auth_pull",
    description:
      "Wait for an approval or revoke transaction to mine, then read back the allowance it left. A "
      + "transaction hash alone does not make Auth Pull ready. The confirmed allowance can "
      + "legitimately be lower than what was approved: USDC decrements it on every pull, so an "
      + "authorization landing in between is a success, not a failure. If the result comes back "
      + "`pending`, do not approve again. Pass the same `chain` the approval reported.",
    inputSchema: objectSchema(
      [
        "chain": authPullChainProperty,
        "transaction_hash": .object([
          "type": "string",
          "description": "Hash returned by approve_auth_pull or revoke_auth_pull.",
        ]),
        "amount": .object([
          "type": "string",
          "description": .string(
            "What was approved, exactly as that tool reported it: a decimal string, \"0\" for a "
            + "revoke, or \"unlimited\"."),
        ]),
      ], required: ["transaction_hash", "amount"]),
    activityLabel: "Confirming on-chain"
  ) { input in
    let chain = try resolveAuthPullChain(input)
    let token = authPullToken(chain)
    guard let hash = input["transaction_hash"]?.stringValue, !hash.isEmpty else {
      throw ToolError("Missing transaction_hash.")
    }
    let raw = input["amount"]?.stringValue?.trimmingCharacters(in: .whitespaces) ?? ""
    let amount: Decimal?
    if raw.isEmpty || raw.caseInsensitiveCompare("unlimited") == .orderedSame {
      amount = nil
    } else if let value = Decimal(string: raw), value >= 0 {
      amount = value
    } else {
      throw ToolError("Invalid amount '\(raw)'. Pass the approved decimal amount, \"0\", or \"unlimited\".")
    }

    var fields = targetJSON(chain: chain, token: token)
    fields["transaction_hash"] = .string(hash)
    do {
      let confirmed = try await client.confirmTokenAllowance(
        transactionHash: hash,
        chainId: chain.chainId,
        contractAddress: token.address,
        spender: operatorAddress,
        amount: amount
      )
      fields["status"] = "confirmed"
      fields["owner"] = .string(confirmed.owner)
      fields["allowance"] = allowanceJSON(confirmed)
      return jsonString(.object(fields))
    } catch let error as RainSDKError {
      // The 60s poll window expiring means "not mined yet", not "failed". Re-approving here would
      // charge the user for a second approval on top of one that is still in flight.
      guard case .networkError = error else { throw error }
      fields["status"] = "pending"
      fields["note"] = .string(
        "Not mined within the SDK's 60s window. The transaction may still succeed. Do not approve "
          + "again; check get_auth_pull_status in a minute.")
      return jsonString(.object(fields))
    }
  }

  return [
    getAuthPullStatus,
    estimateAuthPullFee,
    approveAuthPull,
    revokeAuthPull,
    confirmAuthPull,
  ]
}
