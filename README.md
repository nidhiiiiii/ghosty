# Aquifer

Aquifer is a proof of concept for quoting swaps between an ERC-4626 vault share and its underlying asset at the vault's live `convertToAssets` rate. A custom 1inch SwapVM Extruction applies a maker spread and rejects rates outside maker-selected bounds. Aqua can then account for the maker's liquidity without depositing it into an AMM.

This repository is a demo, not audited production software.

## What is implemented

- `Vault4626Extruction`: live ERC-4626 pricing for exact-input and exact-output swaps, spread, rate bounds, pair validation, rounding, and liquidity checks.
- `AquiferStrategy`: byte encoding for both the deployed/tagged SwapVM v1.0.2 Extruction ABI and current SwapVM main.
- Foundry deployment scripts for local mocks, a mainnet fork, and optional Sepolia mocks.
- An official-SDK TypeScript CLI that prepares orders, ships Aqua allocations, quotes, and submits fills.
- A read-only Next.js strategy builder. It reads vault metadata directly from an RPC and copies a CLI command; it deliberately does not submit strategy calldata from the browser.

## Requirements and setup

- Node.js 22 or newer
- npm
- Foundry (`forge`, `anvil`, and `cast`)
- An Ethereum RPC URL for fork or public-network use

Install dependencies and check the project:

```bash
npm ci
forge build
forge test
npm run typecheck
npm run lint
npm run build
```

Foundry resolves OpenZeppelin and `forge-std` from the npm lockfile, so `npm ci` installs the exact Solidity
dependencies used by the contracts, scripts, and tests. No git submodules are required.

Copy `.env.example` to `.env` and fill only the values needed for the command being run. Never use a funded production key in a checked-in env file.

## Local mock demo

Start Anvil:

```bash
anvil
```

In another terminal, deploy a mock six-decimal asset, a mock ERC-4626 vault, and the Extruction:

```bash
forge script script/DeployLocalDemo.s.sol:DeployLocalDemo \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast
```

Copy the printed vault and Extruction addresses, then inspect the exact strategy bytes with the CLI:

```bash
VAULT=<printed-vault> \
EXTRUCTION_TARGET=<printed-extruction> \
MAKER_ADDRESS=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 \
npm run aqua -- prepare --rpc-url http://127.0.0.1:8545
```

To use the UI, create `frontend/.env.local`:

```dotenv
NEXT_PUBLIC_LOCAL_RPC_URL=http://127.0.0.1:8545
NEXT_PUBLIC_EXTRUCTION_ADDRESS=<printed-extruction>
```

Then run `npm run dev --workspace frontend`, select **Local fork**, and paste the printed vault address.

This local script demonstrates vault pricing and instruction construction. It does not deploy the official Aqua or SwapVM contracts, so it is not by itself an end-to-end Aqua fill environment.

The Solidity suite currently covers both SwapVM register layouts, exact-input and exact-output pricing in both
directions, decimal conversion, spread rounding, maker bounds, malformed configuration, insufficient liquidity,
quote/fill determinism, donation-induced rate changes, and fuzzed amounts/spreads.

## Mainnet-fork demo

Start a fork and deploy only the custom Extruction against real vault state:

```bash
export MAINNET_RPC_URL=<your-rpc-url>
anvil --fork-url "$MAINNET_RPC_URL"

VAULT=0x83F20F44975D03b1b09e64809B757c47f942BEeA \
forge script script/DeployForkDemo.s.sol:DeployForkDemo \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast
```

The example vault is mainnet sDAI; another ERC-4626 vault can be supplied. Use the printed target with `npm run aqua -- prepare` or the frontend as shown above.

The CLI's additional commands are:

```bash
npm run aqua -- ship  --rpc-url <url>
npm run aqua -- quote --rpc-url <url>
npm run aqua -- fill  --rpc-url <url>
```

`ship` needs `MAKER_PRIVATE_KEY`, plus maker-owned balances configured by `SHARE_LIQUIDITY` and `ASSET_LIQUIDITY`. `quote` needs `MAKER_ADDRESS`; `fill` additionally needs `TAKER_PRIVATE_KEY`. `VAULT` and `EXTRUCTION_TARGET` are always required. The default Aqua and router addresses can be overridden with `AQUA_ADDRESS` and `AQUA_ROUTER`.

A fork preserves contract state but does not automatically give an Anvil account suitable token balances, approvals, or a resolver credential. Fund or impersonate appropriate accounts before claiming an end-to-end fill.

## Optional Sepolia deployment

Sepolia deployment is only a public mock demonstration:

```bash
PRIVATE_KEY=<sepolia-demo-key> \
forge script script/DeploySepoliaDemo.s.sol:DeploySepoliaDemo \
  --rpc-url "$SEPOLIA_RPC_URL" \
  --broadcast
```

It deploys a permissionless mock token, mock vault, and the custom Extruction, then prints both instruction layouts. Do not put real value in the mocks. This script does not deploy Aqua or SwapVM; shipping and filling require compatible protocol deployments and the corresponding addresses.

## Architecture

```text
Next.js UI ──RPC reads──> ERC-4626 vault
     │                         │
     └──copies CLI config      └──asset(), metadata, convertToAssets()
              │
              v
TypeScript CLI ──official SDKs──> Aqua.ship(strategy, allocations)
                                      │
maker wallet <──virtual liquidity─────┘
     ^
     │ token movement during a fill
SwapVM router ──Extruction opcode──> Vault4626Extruction
                                         │
                                         ├──live vault rate
                                         ├──maker spread
                                         └──min/max rate guard
```

The instruction is `opcode || 0x94 || target || abi.encode(vault, spreadBps, minRate, maxRate)`. Opcode `0x20` targets the deployed/tagged v1.0.2 layout; `0x04` targets current SwapVM main. These layouts are not interchangeable.

## Limitations and security

- The contracts and app are unaudited and intended for demonstration.
- ERC-4626 conversion rates can be manipulated through donations or vault-specific accounting. Bounds are a circuit breaker, not an oracle or manipulation proof.
- Tokens with transfer fees, rebasing behavior, unusual metadata, or non-standard ERC-4626 semantics have not been qualified.
- The frontend preview uses integer arithmetic but is not an executable quote and does not model gas, transaction ordering, or state changes before inclusion.
- The UI only connects a wallet to identify the account/network and copy a command. It does not ship or fill.
- Public RPC endpoints are rate limited and unsuitable for reliable production service.
- Production Aqua takers/resolvers require 1inch KYB/KYC approval and the chain's resolver credential/NFT. Setting `I_HAVE_AQUA_RESOLVER_CREDENTIAL=true` only acknowledges that requirement in the CLI; it does not grant or bypass the credential.
- No production deployment, solver service, monitoring, upgrade path, or emergency response process is included.

## Sponsor integration notes

### 1inch Aqua and SwapVM

- `scripts/aqua.ts` uses `@1inch/aqua-sdk` to encode `ship` transactions and calculate strategy hashes.
- The same CLI uses `@1inch/swap-vm-sdk` for orders, maker/taker traits, quote calldata, and swap calldata.
- `src/Vault4626Extruction.sol` implements both quote/static and swap Extruction interfaces.
- `src/libraries/AquiferStrategy.sol` builds the custom SwapVM instruction for the two supported register layouts.

The installed Aqua and SwapVM SDK releases pin adjacent versions of `@1inch/sdk-core`. The CLI crosses that package boundary by reconstructing Aqua's exported `Address` and `HexString` values from canonical hex, rather than relying on unsafe casts.

No other sponsor integration is implemented. In particular, the current frontend reads RPC endpoints directly and does not use The Graph; any broader sponsor ideas in `STRATEGY.md` are planning notes, not shipped functionality.
