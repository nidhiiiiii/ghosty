import {
  ABI,
  Address,
  MakerTraits,
  Order,
  SwapVmProgram,
  SwapVMContract,
  TakerTraits,
} from "@1inch/swap-vm-sdk";
import {
  Address as AquaAddress,
  AquaProtocolContract,
  HexString as AquaHexString,
} from "@1inch/aqua-sdk";
import {
  concatHex,
  createPublicClient,
  createWalletClient,
  decodeFunctionResult,
  encodeAbiParameters,
  formatUnits,
  http,
  isAddress,
  parseUnits,
  type Account,
  type Address as EvmAddress,
  type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";

const AQUA = "0x1111113ccf1426a8e30e2bff5e005d929bf6a90a";
const ROUTER = "0x111111338c5091e8440b67b168bae16a668ac0de";
const SEPOLIA_ROUTER = "0x1111113db0e0ef9d0e3a50d5f094a3a57a26c0de";
const BPS = 10_000n;

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
    name: "decimals",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "uint8" }],
  },
  {
    type: "function",
    name: "convertToAssets",
    stateMutability: "view",
    inputs: [{ type: "uint256" }],
    outputs: [{ type: "uint256" }],
  },
] as const;

const erc20Abi = [
  {
    type: "function",
    name: "decimals",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "uint8" }],
  },
  {
    type: "function",
    name: "approve",
    stateMutability: "nonpayable",
    inputs: [{ type: "address" }, { type: "uint256" }],
    outputs: [{ type: "bool" }],
  },
] as const;

function loadEnvironment() {
  try {
    process.loadEnvFile();
  } catch {
    // A .env file is optional; production secrets should usually stay in the shell environment.
  }
}

function flag(name: string) {
  const index = process.argv.indexOf(name);
  return index === -1 ? undefined : process.argv[index + 1];
}

function required(name: string, value = process.env[name]) {
  if (!value) throw new Error(`Missing ${name}.`);
  return value;
}

function integer(name: string, fallback: number) {
  const raw = process.env[name];
  const value = raw === undefined ? fallback : Number(raw);
  if (!Number.isSafeInteger(value) || value < 0) throw new Error(`${name} must be a non-negative integer.`);
  return value;
}

function privateAccount(name: string): Account {
  const key = required(name);
  if (!/^0x[0-9a-fA-F]{64}$/.test(key)) throw new Error(`${name} must be a 32-byte 0x-prefixed key.`);
  return privateKeyToAccount(key as Hex);
}

function assertAddress(name: string, value: string): EvmAddress {
  if (!isAddress(value, { strict: false })) throw new Error(`${name} is not a valid EVM address.`);
  return value;
}

async function context() {
  const rpcUrl = flag("--rpc-url") ?? process.env.RPC_URL ?? "http://127.0.0.1:8545";
  const client = createPublicClient({ transport: http(rpcUrl) });
  const chainId = await client.getChainId();
  const vault = assertAddress("VAULT", required("VAULT"));
  const target = assertAddress("EXTRUCTION_TARGET", required("EXTRUCTION_TARGET"));
  const defaultRouter = chainId === 11_155_111 ? SEPOLIA_ROUTER : ROUTER;
  const router = assertAddress("AQUA_ROUTER", process.env.AQUA_ROUTER ?? defaultRouter);
  const aquaAddress = assertAddress("AQUA_ADDRESS", process.env.AQUA_ADDRESS ?? AQUA);
  const spreadBps = integer("SPREAD_BPS", 15);
  const boundBps = integer("BOUND_BPS", 100);
  if (spreadBps >= Number(BPS)) throw new Error("SPREAD_BPS must be below 10,000.");
  if (boundBps <= 0 || boundBps > 100) throw new Error("BOUND_BPS must be between 1 and 100.");

  const [asset, shareDecimals] = await Promise.all([
    client.readContract({ address: vault, abi: vaultAbi, functionName: "asset" }),
    client.readContract({ address: vault, abi: vaultAbi, functionName: "decimals" }),
  ]);
  const shareUnit = 10n ** BigInt(shareDecimals);
  const [assetDecimals, rate] = await Promise.all([
    client.readContract({ address: asset, abi: erc20Abi, functionName: "decimals" }),
    client.readContract({ address: vault, abi: vaultAbi, functionName: "convertToAssets", args: [shareUnit] }),
  ]);
  if (rate === 0n) throw new Error("Vault returned a zero rate.");

  const minRate = (rate * BigInt(10_000 - boundBps)) / BPS;
  const maxRate = (rate * BigInt(10_000 + boundBps) + BPS - 1n) / BPS;
  const config = encodeAbiParameters(
    [{ type: "address" }, { type: "uint16" }, { type: "uint256" }, { type: "uint256" }],
    [vault, spreadBps, minRate, maxRate],
  );
  const layout = process.env.ROUTER_LAYOUT ?? "deployed";
  if (layout !== "deployed" && layout !== "current") throw new Error("ROUTER_LAYOUT must be deployed or current.");
  if (layout === "current" && (chainId === 1 || chainId === 11_155_111) && router.toLowerCase() === ROUTER) {
    throw new Error("Deployed Aqua on this chain uses opcode 0x20. Set ROUTER_LAYOUT=deployed.");
  }
  const programHex = concatHex([layout === "deployed" ? "0x20" : "0x04", "0x94", target, config]);

  return {
    rpcUrl,
    chainId,
    client,
    vault,
    asset,
    target,
    router,
    aquaAddress,
    shareDecimals,
    assetDecimals,
    shareUnit,
    rate,
    minRate,
    maxRate,
    spreadBps,
    boundBps,
    layout,
    programHex,
  };
}

function buildOrder(programHex: Hex, maker: string) {
  return Order.new({
    maker: new Address(maker),
    program: new SwapVmProgram(programHex),
    traits: MakerTraits.default(),
  });
}

function forAqua(value: { toString(): string }) {
  return new AquaHexString(value.toString());
}

function printContext(ctx: Awaited<ReturnType<typeof context>>) {
  console.log(`Chain:              ${ctx.chainId}`);
  console.log(`Vault:              ${ctx.vault}`);
  console.log(`Asset:              ${ctx.asset}`);
  console.log(`Extruction target:  ${ctx.target}`);
  console.log(`Rate:               ${ctx.rate} asset units / ${ctx.shareUnit} share units`);
  console.log(`Rate bounds:        ${ctx.minRate} .. ${ctx.maxRate}`);
  console.log(`Spread:             ${ctx.spreadBps} bps`);
  console.log(`Router layout:      ${ctx.layout}`);
  console.log(`Program:            ${ctx.programHex}`);
}

async function prepare() {
  const ctx = await context();
  const maker = assertAddress("MAKER_ADDRESS", required("MAKER_ADDRESS"));
  const order = buildOrder(ctx.programHex, maker);
  const strategy = forAqua(order.encode());
  printContext(ctx);
  console.log(`Order:              ${order.encode().toString()}`);
  console.log(`Strategy hash:      ${AquaProtocolContract.calculateStrategyHash(strategy).toString()}`);
}

async function ship() {
  const ctx = await context();
  const maker = privateAccount("MAKER_PRIVATE_KEY");
  const shareAmount = parseUnits(process.env.SHARE_LIQUIDITY ?? "100", ctx.shareDecimals);
  const assetAmount = parseUnits(process.env.ASSET_LIQUIDITY ?? "1000", ctx.assetDecimals);
  const order = buildOrder(ctx.programHex, maker.address);
  const strategy = forAqua(order.encode());
  // The published SDKs pin adjacent sdk-core versions, whose domain classes are
  // nominally typed. Reconstructing Aqua's exported classes from canonical hex
  // keeps the package boundary explicit without unsafe casts.
  const aqua = new AquaProtocolContract(new AquaAddress(ctx.aquaAddress));
  const tx = aqua.ship({
    app: new AquaAddress(ctx.router),
    strategy,
    amountsAndTokens: [
      { token: new AquaAddress(ctx.vault), amount: shareAmount },
      { token: new AquaAddress(ctx.asset), amount: assetAmount },
    ],
  });
  const wallet = createWalletClient({ account: maker, transport: http(ctx.rpcUrl) });
  const max = (1n << 256n) - 1n;
  for (const token of [ctx.vault, ctx.asset] as const) {
    const approval = await wallet.writeContract({
      account: maker,
      chain: null,
      address: token,
      abi: erc20Abi,
      functionName: "approve",
      args: [ctx.aquaAddress, max],
    });
    await ctx.client.waitForTransactionReceipt({ hash: approval });
    console.log(`Aqua approval:      ${approval} (${token})`);
  }

  printContext(ctx);
  console.log(`Order:              ${order.encode().toString()}`);
  console.log(`Share allocation:   ${formatUnits(shareAmount, ctx.shareDecimals)}`);
  console.log(`Asset allocation:   ${formatUnits(assetAmount, ctx.assetDecimals)}`);
  const hash = await wallet.sendTransaction({
    account: maker,
    chain: null,
    to: tx.to,
    data: tx.data,
    value: tx.value,
  });
  console.log(`Shipped transaction: ${hash}`);
  console.log(`Strategy hash:       ${AquaProtocolContract.calculateStrategyHash(strategy).toString()}`);
}

async function quote(fill = false) {
  const ctx = await context();
  const maker = assertAddress("MAKER_ADDRESS", required("MAKER_ADDRESS"));
  const taker = fill
    ? privateAccount("TAKER_PRIVATE_KEY")
    : undefined;
  const takerAddress = taker?.address ?? assertAddress(
    "TAKER_ADDRESS",
    process.env.TAKER_ADDRESS ?? "0x0000000000000000000000000000000000000001",
  );
  const sharesIn = (process.env.DIRECTION ?? "shares-to-asset") === "shares-to-asset";
  const inputDecimals = sharesIn ? ctx.shareDecimals : ctx.assetDecimals;
  const amount = parseUnits(process.env.AMOUNT ?? "1", inputDecimals);
  const order = buildOrder(ctx.programHex, maker);
  const swapVm = new SwapVMContract(new Address(ctx.router));
  const args = {
    order,
    tokenIn: new Address(sharesIn ? ctx.vault : ctx.asset),
    tokenOut: new Address(sharesIn ? ctx.asset : ctx.vault),
    amount,
    takerTraits: TakerTraits.default(),
  };
  const quoteTx = swapVm.quote(args);
  const result = await ctx.client.call({
    account: takerAddress,
    to: quoteTx.to,
    data: quoteTx.data,
  });
  if (!result.data) throw new Error("Router quote returned no data.");
  const [amountIn, amountOut, orderHash] = decodeFunctionResult({
    abi: ABI.SWAP_VM_ABI,
    functionName: "quote",
    data: result.data,
  });

  if (!fill && (process.argv.includes("--json") || process.env.AQUA_JSON === "1")) {
    const outputDecimals = sharesIn ? ctx.assetDecimals : ctx.shareDecimals;
    console.log(JSON.stringify({
      chainId: ctx.chainId,
      router: ctx.router,
      aqua: ctx.aquaAddress,
      vault: ctx.vault,
      asset: ctx.asset,
      target: ctx.target,
      program: ctx.programHex,
      amountIn: amountIn.toString(),
      amountOut: amountOut.toString(),
      formattedOut: formatUnits(amountOut, outputDecimals),
      orderHash,
    }));
    return;
  }

  printContext(ctx);
  console.log(`Quote amount in:    ${amountIn}`);
  console.log(`Quote amount out:   ${amountOut}`);
  console.log(`Order hash:         ${orderHash}`);
  if (!fill) return;

  if (ctx.chainId !== 31_337 && process.env.I_HAVE_AQUA_RESOLVER_CREDENTIAL !== "true") {
    throw new Error(
      "Fill intentionally stopped: production Aqua takers require resolver KYB/KYC and the chain's resolver NFT. " +
      "Set I_HAVE_AQUA_RESOLVER_CREDENTIAL=true only for the credentialed taker EOA.",
    );
  }

  const wallet = createWalletClient({ account: taker!, transport: http(ctx.rpcUrl) });
  const approval = await wallet.writeContract({
    account: taker!,
    chain: null,
    address: sharesIn ? ctx.vault : ctx.asset,
    abi: erc20Abi,
    functionName: "approve",
    args: [ctx.router, amountIn],
  });
  await ctx.client.waitForTransactionReceipt({ hash: approval });
  console.log(`Router approval:    ${approval}`);

  const swapTx = swapVm.swap(args);
  const swapHash = await wallet.sendTransaction({
    account: taker!,
    chain: null,
    to: swapTx.to,
    data: swapTx.data,
    value: swapTx.value,
  });
  console.log(`Fill transaction:   ${swapHash}`);
}

function usage() {
  console.log(`Aquifer Aqua CLI

Usage:
  npm run aqua -- prepare --rpc-url <url>
  npm run aqua -- ship    --rpc-url <url>
  npm run aqua -- quote   --rpc-url <url>
  npm run aqua -- fill    --rpc-url <url>

Required:
  VAULT, EXTRUCTION_TARGET
  MAKER_ADDRESS (prepare/quote/fill) or MAKER_PRIVATE_KEY (ship)
  TAKER_PRIVATE_KEY (fill only)

Optional:
  ROUTER_LAYOUT=deployed|current, SPREAD_BPS, BOUND_BPS,
  SHARE_LIQUIDITY, ASSET_LIQUIDITY, DIRECTION, AMOUNT,
  AQUA_ADDRESS, AQUA_ROUTER, RPC_URL
`);
}

async function main() {
  loadEnvironment();
  const command = process.argv[2];

  try {
    if (command === "prepare") await prepare();
    else if (command === "ship") await ship();
    else if (command === "quote") await quote();
    else if (command === "fill") await quote(true);
    else usage();
  } catch (error) {
    console.error(error instanceof Error ? error.message : error);
    process.exitCode = 1;
  }
}

void main();
