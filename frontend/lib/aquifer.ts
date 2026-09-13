import {
  concatHex,
  createPublicClient,
  encodeAbiParameters,
  formatUnits,
  http,
  isAddress,
  parseUnits,
  type Address,
  type Chain,
  type Hex,
} from "viem";
import { mainnet, sepolia } from "viem/chains";

export const AQUA_ADDRESS = "0x1111113ccf1426a8e30e2bff5e005d929bf6a90a" as Address;
export const AQUA_ROUTER_ADDRESS = "0x111111338c5091e8440b67b168bae16a668ac0de" as Address;
export const SEPOLIA_AQUA_ROUTER_ADDRESS = "0x1111113db0e0ef9d0e3a50d5f094a3a57a26c0de" as Address;
export const SEPOLIA_VAULT = "0x41d10D455d6171dBeCa64Fb3bFAC9110C5780B7C" as Address;
export const SEPOLIA_EXTRUCTION = "0x08fdB26236DCf0A612Fca3da581B41ecbc99c89a" as Address;

const anvil: Chain = {
  id: 31337,
  name: "Anvil",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: ["http://127.0.0.1:8545"] } },
};

export const networks = {
  mainnet: {
    chain: mainnet,
    label: "Ethereum",
    rpcUrl: process.env.NEXT_PUBLIC_MAINNET_RPC_URL ?? "https://ethereum-rpc.publicnode.com",
  },
  sepolia: {
    chain: sepolia,
    label: "Sepolia",
    rpcUrl: process.env.NEXT_PUBLIC_SEPOLIA_RPC_URL ?? "https://ethereum-sepolia-rpc.publicnode.com",
  },
  local: {
    chain: anvil,
    label: "Local fork",
    rpcUrl: "/api/rpc/local",
  },
} as const;

export type NetworkKey = keyof typeof networks;

const vaultAbi = [
  {
    type: "function",
    name: "asset",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "address" }],
  },
  {
    type: "function",
    name: "name",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "string" }],
  },
  {
    type: "function",
    name: "symbol",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "string" }],
  },
  {
    type: "function",
    name: "decimals",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "uint8" }],
  },
  {
    type: "function",
    name: "convertToAssets",
    stateMutability: "view",
    inputs: [{ type: "uint256", name: "shares" }],
    outputs: [{ type: "uint256" }],
  },
] as const;

const tokenAbi = [
  vaultAbi[1],
  vaultAbi[2],
  vaultAbi[3],
] as const;

export interface VaultMetadata {
  vault: Address;
  asset: Address;
  name: string;
  symbol: string;
  shareDecimals: number;
  assetName: string;
  assetSymbol: string;
  assetDecimals: number;
  shareUnit: bigint;
  rate: bigint;
}

export async function readVault(network: NetworkKey, value: string): Promise<VaultMetadata> {
  if (!isAddress(value, { strict: false })) throw new Error("Enter a valid EVM vault address.");
  const vault = value as Address;
  const selected = networks[network];
  const client = createPublicClient({ chain: selected.chain, transport: http(selected.rpcUrl) });

  const [bytecode, asset, name, symbol, shareDecimals] = await Promise.all([
    client.getCode({ address: vault }),
    client.readContract({ address: vault, abi: vaultAbi, functionName: "asset" }),
    client.readContract({ address: vault, abi: vaultAbi, functionName: "name" }),
    client.readContract({ address: vault, abi: vaultAbi, functionName: "symbol" }),
    client.readContract({ address: vault, abi: vaultAbi, functionName: "decimals" }),
  ]);
  if (!bytecode || bytecode === "0x") throw new Error("No contract is deployed at this address.");

  const shareUnit = 10n ** BigInt(shareDecimals);
  const [assetName, assetSymbol, assetDecimals, rate] = await Promise.all([
    client.readContract({ address: asset, abi: tokenAbi, functionName: "name" }),
    client.readContract({ address: asset, abi: tokenAbi, functionName: "symbol" }),
    client.readContract({ address: asset, abi: tokenAbi, functionName: "decimals" }),
    client.readContract({
      address: vault,
      abi: vaultAbi,
      functionName: "convertToAssets",
      args: [shareUnit],
    }),
  ]);
  if (rate === 0n) throw new Error("The vault returned a zero conversion rate.");

  return {
    vault,
    asset,
    name,
    symbol,
    shareDecimals,
    assetName,
    assetSymbol,
    assetDecimals,
    shareUnit,
    rate,
  };
}

export function buildPreview(
  metadata: VaultMetadata,
  amount: string,
  sharesIn: boolean,
  spreadBps: number,
) {
  const inputDecimals = sharesIn ? metadata.shareDecimals : metadata.assetDecimals;
  const outputDecimals = sharesIn ? metadata.assetDecimals : metadata.shareDecimals;
  const amountIn = parseUnits(amount || "0", inputDecimals);
  const fairOut = sharesIn
    ? (amountIn * metadata.rate) / metadata.shareUnit
    : (amountIn * metadata.shareUnit) / metadata.rate;
  const amountOut = (fairOut * BigInt(10_000 - spreadBps)) / 10_000n;

  return {
    amountIn,
    amountOut,
    formattedOut: formatUnits(amountOut, outputDecimals),
  };
}

export const MAX_BOUND_BPS = 100;

export function rateBounds(rate: bigint, boundBps: number) {
  const clamped = Math.min(Math.max(boundBps, 1), MAX_BOUND_BPS);
  const minRate = (rate * BigInt(10_000 - clamped)) / 10_000n;
  return {
    minRate: minRate === 0n ? 1n : minRate,
    maxRate: (rate * BigInt(10_000 + clamped) + 9_999n) / 10_000n,
  };
}

export function buildInstruction(
  target: string,
  metadata: VaultMetadata,
  spreadBps: number,
  boundBps: number,
  deployedRouter: boolean,
): Hex | null {
  if (!isAddress(target, { strict: false })) return null;
  const { minRate, maxRate } = rateBounds(metadata.rate, boundBps);
  const config = encodeAbiParameters(
    [
      { type: "address" },
      { type: "uint16" },
      { type: "uint256" },
      { type: "uint256" },
    ],
    [metadata.vault, spreadBps, minRate, maxRate],
  );
  return concatHex([
    deployedRouter ? "0x20" : "0x04",
    "0x94",
    target as Address,
    config,
  ]);
}

export function compactAddress(address: string) {
  return `${address.slice(0, 6)}…${address.slice(-4)}`;
}

export function formatRate(metadata: VaultMetadata) {
  return formatUnits(metadata.rate, metadata.assetDecimals);
}

const extructionV102Abi = [
  {
    type: "function",
    name: "extruction",
    stateMutability: "view",
    inputs: [
      { name: "isStaticContext", type: "bool" },
      { name: "nextPC", type: "uint256" },
      {
        name: "query",
        type: "tuple",
        components: [
          { name: "orderHash", type: "bytes32" },
          { name: "maker", type: "address" },
          { name: "taker", type: "address" },
          { name: "tokenIn", type: "address" },
          { name: "tokenOut", type: "address" },
          { name: "isExactIn", type: "bool" },
        ],
      },
      {
        name: "swap",
        type: "tuple",
        components: [
          { name: "balanceIn", type: "uint256" },
          { name: "balanceOut", type: "uint256" },
          { name: "amountIn", type: "uint256" },
          { name: "amountOut", type: "uint256" },
          { name: "amountNetPulled", type: "uint256" },
        ],
      },
      { name: "args", type: "bytes" },
      { name: "takerData", type: "bytes" },
    ],
    outputs: [
      { name: "updatedNextPC", type: "uint256" },
      { name: "choppedLength", type: "uint256" },
      {
        name: "updatedSwap",
        type: "tuple",
        components: [
          { name: "balanceIn", type: "uint256" },
          { name: "balanceOut", type: "uint256" },
          { name: "amountIn", type: "uint256" },
          { name: "amountOut", type: "uint256" },
          { name: "amountNetPulled", type: "uint256" },
        ],
      },
    ],
  },
] as const;

export async function quoteOnChain(
  network: NetworkKey,
  target: string,
  metadata: VaultMetadata,
  amount: string,
  sharesIn: boolean,
  spreadBps: number,
  boundBps: number,
) {
  if (!isAddress(target, { strict: false })) throw new Error("Add the deployed Extruction address.");
  const inputDecimals = sharesIn ? metadata.shareDecimals : metadata.assetDecimals;
  const outputDecimals = sharesIn ? metadata.assetDecimals : metadata.shareDecimals;
  const specified = parseUnits(amount || "0", inputDecimals);
  if (specified === 0n) throw new Error("Enter an amount greater than zero.");

  const { minRate, maxRate } = rateBounds(metadata.rate, boundBps);
  const args = encodeAbiParameters(
    [
      { type: "address" },
      { type: "uint16" },
      { type: "uint256" },
      { type: "uint256" },
    ],
    [metadata.vault, spreadBps, minRate, maxRate],
  );
  const selected = networks[network];
  const client = createPublicClient({ chain: selected.chain, transport: http(selected.rpcUrl) });
  const [, , updated] = await client.readContract({
    address: target as Address,
    abi: extructionV102Abi,
    functionName: "extruction",
    args: [
      true,
      0n,
      {
        orderHash: "0x0000000000000000000000000000000000000000000000000000000000000001",
        maker: "0x0000000000000000000000000000000000000001",
        taker: "0x0000000000000000000000000000000000000002",
        tokenIn: sharesIn ? metadata.vault : metadata.asset,
        tokenOut: sharesIn ? metadata.asset : metadata.vault,
        isExactIn: true,
      },
      {
        balanceIn: (1n << 128n) - 1n,
        balanceOut: (1n << 128n) - 1n,
        amountIn: specified,
        amountOut: 0n,
        amountNetPulled: 0n,
      },
      args,
      "0x",
    ],
  });

  return {
    amountIn: updated.amountIn,
    amountOut: updated.amountOut,
    formattedOut: formatUnits(updated.amountOut, outputDecimals),
  };
}

export function aquaRouterFor(network: NetworkKey) {
  return network === "sepolia" ? SEPOLIA_AQUA_ROUTER_ADDRESS : AQUA_ROUTER_ADDRESS;
}
