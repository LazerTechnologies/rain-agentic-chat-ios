# Rain Agent Demo

An agentic chat app showcasing the **Rain iOS SDK**. The user logs in with **Privy or Turnkey** (email OTP either way), gets a wallet, and chats with a Claude-powered assistant that operates the wallet through Rain SDK tools:

- **Read:** balances across chains, transaction history
- **Analyze:** natural-language spending insights from on-chain history
- **Act (gated):** send native/ERC-20 tokens, withdraw card collateral, approve or revoke the Auth Pull allowance, always behind a native confirmation sheet
- **Rain issuing API:** collateral contracts, admin-signature withdrawal flow, fee estimation
- **Auth Pull:** check whether a card authorization can pull USDC from this wallet, price the approval, approve or revoke it, and confirm it on-chain

## How it works

```
User message
   -> Claude (Messages API, tool use, adaptive thinking)
   -> tool_use: e.g. get_wallet_overview
   -> app executes the real Rain SDK call (the selected provider signs)
   -> tool_result back to Claude
   -> ... loop ...
   -> final answer in chat
```

Claude only ever *decides* which Rain SDK method to call. Execution and signing stay with the wallet provider the user logged in with. Irreversible tools (`send_native`, `send_token`, `withdraw_collateral`, `approve_auth_pull`, `revoke_auth_pull`) suspend the loop on a SwiftUI confirmation sheet; declining returns a "user declined" result to the model.

## Setup

1. Fill in your keys in `RainAgentDemo/AgentLocalConfig.swift`. It ships tracked but empty,
   with a format example beside each field. **Keep your filled-in copy local — don't commit
   real keys.** To stop git from offering your edits for commit:
   ```sh
   git update-index --skip-worktree RainAgentDemo/AgentLocalConfig.swift
   ```

   | Field | Where from | Required? |
   | --- | --- | --- |
   | `anthropicAPIKey` | console.anthropic.com | Yes, unless using a proxy (below) |
   | `claudeProxyBaseURL` / `claudeProxyToken` / `claudeProxyModel` | your own Claude proxy | Alternative to the key above; when the base URL is set, traffic goes to `<base>/v1/chat/completions` in OpenAI wire format and `anthropicAPIKey` is ignored |
   | `privyAppId` / `privyAppClientId` | Privy dashboard (app settings → clients) | For the Privy login option |
   | `turnkeyOrganizationId` / `turnkeyAuthProxyConfigId` | Turnkey dashboard → Auth Proxy | For the Turnkey login option |
   | `rainApiKey` / `rainUserId` | Rain issuing API (dev) | Optional; collateral tools need them, wallet tools don't |
   | `rainAuthPullOperator` | Rain's [Auth Pull docs](https://docs.rain.xyz/docs/authorization-pull-from-user-wallet), sandbox operator | Optional; empty leaves the Auth Pull tools unregistered |

   Fill in at least one wallet provider's pair — the login screen disables the other and says why.
2. Open and run:
   ```sh
   open RainAgentDemo.xcodeproj
   ```
   iOS 17+ simulator or device. First package resolution pulls the Privy binary SDK, Turnkey's Swift SDK, and the Web3 stack, so the first build is slow.

The Xcode project is generated from `project.yml` by [XcodeGen](https://github.com/yonaskolb/XcodeGen) and checked in, so a plain clone needs no extra tooling. Only if you change `project.yml`: `brew install xcodegen && xcodegen generate`.

### Rain SDK dependency

The Rain SDK is consumed from source — `github.com/lazerfocused/rain-sdk-ios`, branch
`feature/auth_pull_impl` (the modular-providers branch plus Auth Pull) — linking the
`rain-core-ios` and `rain-privy-ios` products (imported as `RainCore` and `RainPrivy`). Nothing is
vendored, and `Package.resolved` pins the exact revision.

The Turnkey adapter ships inside `rain-core-ios`, so Turnkey needs no extra Rain product — only Turnkey's own SDK (`tkhq/swift-sdk`, pinned to the version `rain-core-ios` resolves) for the auth flow the app drives itself.

## Wallet providers

Both register on the `RainSdk` builder and resolve to the same `RainClient`, so every agent tool is provider-agnostic: email OTP either way, Privy giving an embedded Ethereum wallet and Turnkey a sub-org account (secp256k1, `m/44'/60'/0'/0/0`), both created on first login and resumed at launch.
Turnkey auth is app-owned — see `TurnkeyAuthService` — because the Rain SDK deliberately does not own vendor auth.

## Demo script

1. "What's in my wallet?" (agent calls `get_wallet_overview`, formats holdings)
2. "Analyze my recent spending" (agent pulls history and writes a narrative summary)
3. "Send 1 USDC to 0x..." (agent restates the transfer, native confirm sheet appears, tx hash + Basescan link on approval; try declining first)
4. "What's in my collateral wallet?" (agent calls `get_collateral_contracts` — contract addresses, held tokens, balances)
5. "What would it cost to withdraw 5 USDC?" then "Withdraw 5 USDC from my collateral wallet" (agent estimates via `estimate_withdrawal_fee`, then `withdraw_collateral` fetches the admin signature, signs, and submits on-chain behind the confirmation sheet)
6. "Can my card pull USDC from this wallet?" (`get_auth_pull_status`: the allowance Rain's operator holds, plus the USDC and gas a pull and an approval need)
7. "Approve it" (`approve_auth_pull` unlimited behind the confirmation sheet, then `confirm_auth_pull` waits for the receipt and reads the allowance back); "Revoke it" runs the same flow to zero

Steps 4 and 5 need `rainApiKey` / `rainUserId` set; the wallet tools above them don't. Steps 6 and 7
need `rainAuthPullOperator`, plus a wallet holding Base Sepolia USDC ([Circle faucet](https://faucet.circle.com/))
and ETH for gas.

## Production notes

The API key ships on-device for demo convenience — in production, put it behind a backend proxy (OpenRouter, your own gateway) via `claudeProxyBaseURL`.

## Architecture

```
RainAgentDemo/
  Core/Services/   PrivyAuthService (email OTP, embedded wallet)
                   TurnkeyAuthService (email OTP via auth proxy, sub-org wallet)
                   RainService (RainSdk builder + resolved RainClient, either provider)
  Core/Agent/      AnthropicModels / AnthropicClient (raw Messages API)
                   ToolRegistry / RainTools (8 tools over RainClient/RainSdk)
                   AuthPullTools (5 Auth Pull tools, registered only when configured)
                   AgentLoop (tool-use loop + confirmation gate)
                   SystemPrompt
  Presentation/    Auth (provider picker, login/OTP), Chat (bubbles, tool pills, confirm sheet)
```

Money amounts are strings end-to-end (`Decimal`, never `Double`), matching the SDK's Decimal-first contract. Thinking blocks are round-tripped verbatim as the API requires.
