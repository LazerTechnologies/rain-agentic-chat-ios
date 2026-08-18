import Foundation
import BigInt
import RainCore

// MARK: - Amount helpers

enum AmountMath {
  /// Parses a human-unit decimal amount string. Never goes through Double.
  static func parseAmount(_ raw: String?) throws -> Decimal {
    guard let raw, let amount = Decimal(string: raw), amount > 0 else {
      throw ToolError("Invalid amount '\(raw ?? "")'. Pass a positive decimal number as a string, e.g. \"1.5\".")
    }
    return amount
  }

  /// Normalizes an amount to the token's precision (rounding DOWN) and returns both the
  /// normalized value and its exact base-unit representation. Exact base-10 scaling; a
  /// Double multiply would truncate (16.38 * 1e6 == 16_379_999.99...).
  static func normalized(_ raw: Decimal, decimals: Int) throws -> (value: Decimal, baseUnits: BigUInt) {
    let handler = NSDecimalNumberHandler(
      roundingMode: .down,
      scale: Int16(decimals),
      raiseOnExactness: false,
      raiseOnOverflow: false,
      raiseOnUnderflow: false,
      raiseOnDivideByZero: false
    )
    let rounded = NSDecimalNumber(decimal: raw).rounding(accordingToBehavior: handler)
    guard rounded.doubleValue > 0 else {
      throw ToolError("Amount is below the token's minimum unit (\(decimals) decimals).")
    }
    let scaled = rounded.multiplying(byPowerOf10: Int16(decimals))
    let baseUnits = BigUInt(scaled.stringValue, radix: 10) ?? BigUInt(0)
    return (rounded.decimalValue, baseUnits)
  }
}

// MARK: - Admin signature cache

/// Rain issues one active withdrawal signature per (token, amount, recipient); requesting a
/// second for the same inputs errors with "active signature already exists". Cache the last
/// signature so estimate_withdrawal_fee and withdraw_collateral share it.
actor AdminSignatureCache {
  struct Key: Hashable {
    let chainId: Int
    let tokenAddress: String
    let baseUnits: String
    let recipient: String
  }

  private var key: Key?
  private var signature: RainAdminSignature?

  func signature(for key: Key) -> RainAdminSignature? {
    self.key == key ? signature : nil
  }

  func store(_ signature: RainAdminSignature, for key: Key) {
    self.key = key
    self.signature = signature
  }

  /// Clear after a successful withdrawal: the signature is consumed on-chain.
  func invalidate() {
    key = nil
    signature = nil
  }
}

// MARK: - JSON result helpers

func jsonString(_ value: JSONValue) -> String {
  guard let data = try? JSONEncoder().encode(value),
    let string = String(data: data, encoding: .utf8)
  else { return "{}" }
  return string
}

private func balanceJSON(_ balance: Balance) -> JSONValue {
  var fields: [String: JSONValue] = [
    "amount": .string(balance.formatted),
    "decimals": .number(Double(balance.decimals)),
    "chain": .string(WalletChain.from(chainId: balance.chainId)?.displayName ?? "chain \(balance.chainId)"),
    "chain_id": .number(Double(balance.chainId)),
  ]
  switch balance.token {
  case .native:
    fields["token"] = .string(balance.symbol ?? WalletChain.from(chainId: balance.chainId)?.nativeSymbol ?? "native")
    fields["kind"] = "native"
  case .contract(let address):
    fields["token"] = .string(balance.symbol ?? address)
    fields["contract_address"] = .string(address)
    fields["kind"] = "erc20"
  @unknown default:
    fields["token"] = .string(balance.symbol ?? "unknown")
  }
  return .object(fields)
}

private func transactionJSON(_ tx: RainTransaction) -> JSONValue {
  var fields: [String: JSONValue] = [
    "hash": .string(tx.hash),
    "from": .string(tx.from),
    "chain": .string(WalletChain.from(chainId: tx.chainId)?.displayName ?? "chain \(tx.chainId)"),
  ]
  if let to = tx.to { fields["to"] = .string(to) }
  if let category = tx.category { fields["category"] = .string(category.rawValue) }
  if let block = tx.blockNumber { fields["block"] = .string(block) }
  if let timestamp = tx.timestamp { fields["timestamp"] = .string(timestamp) }
  if let value = tx.value { fields["value"] = .string("\(value)") }
  // Exact base-unit amount, so the model can still reason about rows whose decimals
  // the provider could not resolve (value is nil in that case).
  if let rawValue = tx.rawValue { fields["raw_value"] = .string(rawValue) }
  if let decimals = tx.decimals { fields["decimals"] = .number(Double(decimals)) }
  if let asset = tx.asset { fields["asset"] = .string(asset) }
  if let tokenAddress = tx.tokenAddress { fields["contract_address"] = .string(tokenAddress) }
  if let status = tx.metadata?.status { fields["status"] = .string(status) }
  return .object(fields)
}

// MARK: - Chain resolution

func resolveChain(_ input: JSONValue, default defaultChain: WalletChain) throws -> WalletChain {
  guard let raw = input["chain"]?.stringValue, !raw.isEmpty else { return defaultChain }
  guard let chain = WalletChain(rawValue: raw) else {
    let options = WalletChain.allCases.map(\.rawValue).joined(separator: ", ")
    throw ToolError("Unknown chain '\(raw)'. Valid values: \(options).")
  }
  return chain
}

var chainSchemaProperty: JSONValue {
  .object([
    "type": "string",
    "enum": .array(WalletChain.allCases.map { .string($0.rawValue) }),
    "description": .string("Network to operate on. Defaults to \(AgentLocalConfig.defaultChain.rawValue)."),
  ])
}

func objectSchema(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
  .object([
    "type": "object",
    "properties": .object(properties),
    "required": .array(required.map { .string($0) }),
  ])
}

// MARK: - Tool factory

/// Builds the full tool set against a resolved RainClient + RainSdk. All money amounts are
/// strings in schemas and results (the SDK is Decimal-first; Double caused real bugs).
func makeRainTools(
  client: RainClient,
  rain: RainSdk,
  walletAddress: String,
  defaultChain: WalletChain
) -> [AgentTool] {
  let signatureCache = AdminSignatureCache()

  // Turnkey sources history from its own activity index, so it lists only what this wallet sent
  // through Turnkey. Reported with the results: an agent asked to analyze spending must not read
  // that partial set as the full picture.
  let historyCoverage: String? =
    client.providerId == .turnkey
    ? "Turnkey lists only transactions this wallet sent through Turnkey — incoming transfers and "
      + "anything signed elsewhere are missing. Rows are recorded as native sends: a token transfer "
      + "shows the token contract in contract_address with a zero native value, not the token amount."
    : nil

  // Shared helper: resolve a token symbol or 0x address to (address, decimals?) using the
  // wallet's current token balances on the chain.
  @Sendable func resolveToken(_ raw: String, chain: WalletChain) async throws -> (address: String, decimals: Int?) {
    if raw.hasPrefix("0x") { return (raw, nil) }  // SDK resolves decimals on-chain
    let balances = try await client.getTokenBalances(chainId: chain.chainId)
    for balance in balances {
      if case .contract(let address) = balance.token,
        balance.symbol?.caseInsensitiveCompare(raw) == .orderedSame
      {
        return (address, balance.decimals)
      }
    }
    throw ToolError(
      "Token '\(raw)' not found in the wallet's balances on \(chain.displayName). "
        + "Pass the token's 0x contract address instead.")
  }

  // Shared helper: full admin-signature flow for the collateral withdrawal tools.
  @Sendable func withdrawalContext(
    _ input: JSONValue
  ) async throws -> (
    contract: RainCollateralContract, chain: WalletChain, token: RainCollateralToken,
    amount: Decimal, baseUnits: BigUInt, decimals: Int, recipient: String,
    signature: RainAdminSignature, cacheKey: AdminSignatureCache.Key
  ) {
    let contract = try await rain.fetchCollateralContract()
    guard let chain = WalletChain.from(chainId: contract.chainId) else {
      throw ToolError("Collateral contract is on unsupported chain id \(contract.chainId).")
    }
    guard let admin = contract.adminAddresses.first else {
      throw ToolError("Collateral contract has no admin address; withdrawals are not possible.")
    }

    let token: RainCollateralToken
    if let requested = input["token_address"]?.stringValue, !requested.isEmpty {
      guard
        let match = contract.tokens.first(where: {
          $0.address.caseInsensitiveCompare(requested) == .orderedSame
        })
      else {
        let known = contract.tokens.map { "\($0.symbol ?? "?") \($0.address)" }.joined(separator: "; ")
        throw ToolError("Token \(requested) is not held by the collateral contract. Held tokens: \(known)")
      }
      token = match
    } else if let first = contract.tokens.first {
      token = first
    } else {
      throw ToolError("The collateral contract holds no tokens.")
    }

    let decimals = token.decimals ?? 6
    let amount = try AmountMath.parseAmount(input["amount"]?.stringValue)
    let normalized = try AmountMath.normalized(amount, decimals: decimals)
    let recipient = input["recipient"]?.stringValue ?? walletAddress

    let cacheKey = AdminSignatureCache.Key(
      chainId: contract.chainId,
      tokenAddress: token.address.lowercased(),
      baseUnits: normalized.baseUnits.description,
      recipient: recipient.lowercased()
    )

    let signature: RainAdminSignature
    if let cached = await signatureCache.signature(for: cacheKey) {
      signature = cached
    } else {
      do {
        signature = try await rain.fetchAdminSignature(
          chainId: contract.chainId,
          tokenAddress: token.address,
          amountBaseUnits: normalized.baseUnits,
          adminAddress: admin,
          recipientAddress: recipient,
          isAmountNative: true
        )
      } catch let error as RainSDKError {
        if case .signatureNotReady(_, let retryAfter) = error {
          // Rain is still preparing the signature; retry once after the hinted delay.
          try await Task.sleep(for: .seconds(min(retryAfter ?? 5, 15)))
          signature = try await rain.fetchAdminSignature(
            chainId: contract.chainId,
            tokenAddress: token.address,
            amountBaseUnits: normalized.baseUnits,
            adminAddress: admin,
            recipientAddress: recipient,
            isAmountNative: true
          )
        } else {
          throw error
        }
      }
      await signatureCache.store(signature, for: cacheKey)
    }

    return (contract, chain, token, normalized.value, normalized.baseUnits, decimals, recipient, signature, cacheKey)
  }

  @Sendable func withdrawAddresses(
    contract: RainCollateralContract, token: RainCollateralToken, recipient: String
  ) -> RainWithdrawAddresses {
    RainWithdrawAddresses(
      proxyAddress: contract.proxyAddress,
      controllerAddress: contract.controllerAddress,
      tokenAddress: token.address,
      recipientAddress: recipient
    )
  }

  // MARK: get_wallet_overview

  let getWalletOverview = AgentTool(
    name: "get_wallet_overview",
    description:
      "Get the user's wallet address and all non-zero token balances (native + ERC-20) on one network. "
      + "Use this first when the user asks what they have.",
    inputSchema: objectSchema(["chain": chainSchemaProperty]),
    activityLabel: "Checking balances"
  ) { input in
    let chain = try resolveChain(input, default: defaultChain)
    let address = try await client.getWalletAddress(chainId: chain.chainId)
    let balances = try await client.getTokenBalances(chainId: chain.chainId)
    return jsonString(
      .object([
        "address": .string(address),
        "chain": .string(chain.displayName),
        "balances": .array(balances.map(balanceJSON)),
      ]))
  }

  // MARK: get_all_balances

  let getAllBalances = AgentTool(
    name: "get_all_balances",
    description:
      "Get balances across every configured network at once. Chains that fail to respond are omitted.",
    inputSchema: objectSchema([:]),
    activityLabel: "Checking balances on all networks"
  ) { _ in
    let balances = try await client.getAllBalances()
    return jsonString(.object(["balances": .array(balances.map(balanceJSON))]))
  }

  // MARK: get_transactions

  let getTransactions = AgentTool(
    name: "get_transactions",
    description:
      "Get the wallet's transaction history on a network, newest first by default. `value` is in "
      + "human-readable token units; rows whose decimals the provider could not resolve carry "
      + "`raw_value` (base units) plus `decimals` instead. Use this for any question about past "
      + "activity or spending.",
    inputSchema: objectSchema([
      "chain": chainSchemaProperty,
      "limit": .object([
        "type": "integer",
        "description": "Max transactions to return (default 20, max 50).",
      ]),
      "offset": .object([
        "type": "integer",
        "description": "Pagination offset (default 0).",
      ]),
      "order": .object([
        "type": "string", "enum": ["asc", "desc"],
        "description": "Sort order by block (default desc = newest first).",
      ]),
    ]),
    activityLabel: "Fetching transaction history"
  ) { input in
    let chain = try resolveChain(input, default: defaultChain)
    let limit = min(max(input["limit"]?.intValue ?? 20, 1), 50)
    let offset = max(input["offset"]?.intValue ?? 0, 0)
    let order: RainTransactionOrder = input["order"]?.stringValue == "asc" ? .ASC : .DESC
    let transactions = try await client.getTransactions(
      chainId: chain.chainId, limit: limit, offset: offset, order: order)

    // Cap the tool_result size so long histories don't blow up the context window.
    var items = transactions.map(transactionJSON)
    var truncated = false
    while items.count > 1, jsonString(.array(items)).utf8.count > 20_000 {
      items.removeLast()
      truncated = true
    }
    var fields: [String: JSONValue] = [
      "chain": .string(chain.displayName),
      "count": .number(Double(items.count)),
      "transactions": .array(items),
    ]
    if truncated { fields["truncated"] = .bool(true) }
    if let historyCoverage { fields["coverage"] = .string(historyCoverage) }
    return jsonString(.object(fields))
  }

  // MARK: send_native

  let sendNative = AgentTool(
    name: "send_native",
    description:
      "Send native gas tokens (ETH on Base Sepolia, AVAX on Avalanche Fuji) to an address. "
      + "Irreversible; the app shows the user a confirmation sheet before executing.",
    inputSchema: objectSchema(
      [
        "chain": chainSchemaProperty,
        "to": .object(["type": "string", "description": "Recipient 0x address."]),
        "amount": .object([
          "type": "string",
          "description": "Amount in human units as a decimal string, e.g. \"0.01\".",
        ]),
      ], required: ["to", "amount"]),
    activityLabel: "Sending",
    requiresConfirmation: true,
    confirmationSummary: { input in
      let chain = try resolveChain(input, default: defaultChain)
      let amount = try AmountMath.parseAmount(input["amount"]?.stringValue)
      let to = input["to"]?.stringValue ?? ""
      return ConfirmationDetails(
        title: "Send \(amount) \(chain.nativeSymbol)",
        fields: [
          .init(label: "Amount", value: "\(amount) \(chain.nativeSymbol)"),
          .init(label: "To", value: to),
          .init(label: "Network", value: chain.displayName),
        ],
        warning: "This transaction is irreversible."
      )
    }
  ) { input in
    let chain = try resolveChain(input, default: defaultChain)
    guard let to = input["to"]?.stringValue, chain.isValidAddress(to) else {
      throw ToolError("Recipient is not a valid 0x address.")
    }
    let amount = try AmountMath.parseAmount(input["amount"]?.stringValue)
    let result = try await client.sendNative(chainId: chain.chainId, to: to, amount: amount)
    let explorer = chain.explorerTxURL(hash: result.transactionHash)?.absoluteString
    return jsonString(
      .object([
        "status": "submitted",
        "transaction_hash": .string(result.transactionHash),
        "explorer_url": .string(explorer ?? ""),
      ]))
  }

  // MARK: send_token

  let sendToken = AgentTool(
    name: "send_token",
    description:
      "Send an ERC-20 token (e.g. USDC) to an address. `token` is a symbol the wallet holds or a 0x "
      + "contract address. Irreversible; the app shows the user a confirmation sheet before executing.",
    inputSchema: objectSchema(
      [
        "chain": chainSchemaProperty,
        "token": .object([
          "type": "string",
          "description": "Token symbol (e.g. \"USDC\") or 0x contract address.",
        ]),
        "to": .object(["type": "string", "description": "Recipient 0x address."]),
        "amount": .object([
          "type": "string",
          "description": "Amount in human units as a decimal string, e.g. \"5\" for 5 USDC.",
        ]),
      ], required: ["token", "to", "amount"]),
    activityLabel: "Sending token",
    requiresConfirmation: true,
    confirmationSummary: { input in
      let chain = try resolveChain(input, default: defaultChain)
      let amount = try AmountMath.parseAmount(input["amount"]?.stringValue)
      let token = input["token"]?.stringValue ?? "?"
      let to = input["to"]?.stringValue ?? ""
      return ConfirmationDetails(
        title: "Send \(amount) \(token)",
        fields: [
          .init(label: "Amount", value: "\(amount) \(token)"),
          .init(label: "To", value: to),
          .init(label: "Network", value: chain.displayName),
        ],
        warning: "This transaction is irreversible."
      )
    }
  ) { input in
    let chain = try resolveChain(input, default: defaultChain)
    guard let to = input["to"]?.stringValue, chain.isValidAddress(to) else {
      throw ToolError("Recipient is not a valid 0x address.")
    }
    guard let rawToken = input["token"]?.stringValue, !rawToken.isEmpty else {
      throw ToolError("Missing token symbol or contract address.")
    }
    let amount = try AmountMath.parseAmount(input["amount"]?.stringValue)
    let token = try await resolveToken(rawToken, chain: chain)
    let result = try await client.sendToken(
      chainId: chain.chainId,
      contractAddress: token.address,
      to: to,
      amount: amount,
      decimals: token.decimals
    )
    let explorer = chain.explorerTxURL(hash: result.transactionHash)?.absoluteString
    return jsonString(
      .object([
        "status": "submitted",
        "transaction_hash": .string(result.transactionHash),
        "explorer_url": .string(explorer ?? ""),
      ]))
  }

  // MARK: get_collateral_contracts

  let getCollateralContracts = AgentTool(
    name: "get_collateral_contracts",
    description:
      "Get the user's Rain collateral contracts (card-backing funds): addresses, held tokens, and balances. "
      + "Requires the app to be configured with Rain issuing API credentials.",
    inputSchema: objectSchema([:]),
    activityLabel: "Fetching collateral contracts"
  ) { _ in
    let contracts = try await rain.fetchCollateralContracts()
    let items: [JSONValue] = contracts.map { contract in
      .object([
        "chain": .string(WalletChain.from(chainId: contract.chainId)?.displayName ?? "chain \(contract.chainId)"),
        "proxy_address": .string(contract.proxyAddress),
        "controller_address": .string(contract.controllerAddress),
        "tokens": .array(
          contract.tokens.map { token in
            .object([
              "symbol": .string(token.symbol ?? "?"),
              "address": .string(token.address),
              "balance": .string(token.balance),
            ])
          }),
      ])
    }
    return jsonString(.object(["contracts": .array(items)]))
  }

  // MARK: estimate_withdrawal_fee

  let estimateWithdrawalFee = AgentTool(
    name: "estimate_withdrawal_fee",
    description:
      "Estimate the network fee for withdrawing collateral from the user's Rain contract. "
      + "Fetches the admin signature and simulates the withdrawal without submitting it.",
    inputSchema: objectSchema(
      [
        "amount": .object([
          "type": "string",
          "description": "Amount to withdraw, human units, decimal string.",
        ]),
        "token_address": .object([
          "type": "string",
          "description": "0x address of the collateral token. Defaults to the contract's first token.",
        ]),
        "recipient": .object([
          "type": "string",
          "description": "Recipient 0x address. Defaults to the user's own wallet.",
        ]),
      ], required: ["amount"]),
    activityLabel: "Estimating withdrawal fee"
  ) { input in
    let context = try await withdrawalContext(input)
    let fee = try await client.estimateWithdrawalFee(
      chainId: context.chain.chainId,
      addresses: withdrawAddresses(
        contract: context.contract, token: context.token, recipient: context.recipient),
      amount: context.amount,
      decimals: context.decimals,
      adminSignature: context.signature
    )
    return jsonString(
      .object([
        "estimated_fee": .string("\(fee)"),
        "fee_token": .string(context.chain.nativeSymbol),
        "withdraw_amount": .string("\(context.amount)"),
        "token": .string(context.token.symbol ?? context.token.address),
        "chain": .string(context.chain.displayName),
      ]))
  }

  // MARK: withdraw_collateral

  let withdrawCollateral = AgentTool(
    name: "withdraw_collateral",
    description:
      "Withdraw collateral from the user's Rain contract to a wallet. Fetches the admin signature, "
      + "builds, signs, and submits the withdrawal on-chain. Irreversible; the app shows the user a "
      + "confirmation sheet before executing.",
    inputSchema: objectSchema(
      [
        "amount": .object([
          "type": "string",
          "description": "Amount to withdraw, human units, decimal string.",
        ]),
        "token_address": .object([
          "type": "string",
          "description": "0x address of the collateral token. Defaults to the contract's first token.",
        ]),
        "recipient": .object([
          "type": "string",
          "description": "Recipient 0x address. Defaults to the user's own wallet.",
        ]),
      ], required: ["amount"]),
    activityLabel: "Withdrawing collateral",
    requiresConfirmation: true,
    confirmationSummary: { input in
      let amount = try AmountMath.parseAmount(input["amount"]?.stringValue)
      return ConfirmationDetails(
        title: "Withdraw \(amount) collateral",
        fields: [
          .init(label: "Amount", value: "\(amount)"),
          .init(label: "To", value: input["recipient"]?.stringValue ?? walletAddress),
        ],
        warning: "This withdraws card-backing collateral on-chain and is irreversible."
      )
    }
  ) { input in
    let context = try await withdrawalContext(input)
    let hash = try await client.withdrawCollateral(
      chainId: context.chain.chainId,
      addresses: withdrawAddresses(
        contract: context.contract, token: context.token, recipient: context.recipient),
      amount: context.amount,
      decimals: context.decimals,
      adminSignature: context.signature
    )
    // The signature is consumed on-chain; the next withdrawal must fetch a fresh one.
    await signatureCache.invalidate()
    let explorer = context.chain.explorerTxURL(hash: hash)?.absoluteString
    return jsonString(
      .object([
        "status": "submitted",
        "transaction_hash": .string(hash),
        "explorer_url": .string(explorer ?? ""),
      ]))
  }

  return [
    getWalletOverview,
    getAllBalances,
    getTransactions,
    sendNative,
    sendToken,
    getCollateralContracts,
    estimateWithdrawalFee,
    withdrawCollateral,
  ] + makeAuthPullTools(client: client, defaultChain: defaultChain)
}
