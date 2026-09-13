import { execFile } from "node:child_process";
import { existsSync } from "node:fs";
import path from "node:path";
import { promisify } from "node:util";

import { NextResponse } from "next/server";
import { isAddress } from "viem";

const execFileAsync = promisify(execFile);

const SEPOLIA_ROUTER = "0x1111113db0e0ef9d0e3a50d5f094a3a57a26c0de";
const MAINNET_ROUTER = "0x111111338c5091e8440b67b168bae16a668ac0de";

function repoRoot() {
  const cwd = process.cwd();
  if (existsSync(path.join(cwd, "scripts/aqua.ts"))) return cwd;
  return path.resolve(cwd, "..");
}

export const dynamic = "force-dynamic";

export async function POST(request: Request) {
  const body = (await request.json()) as {
    network?: string;
    vault?: string;
    target?: string;
    amount?: string;
    sharesIn?: boolean;
    spreadBps?: number;
    boundBps?: number;
    deployedRouter?: boolean;
    maker?: string;
    rpcUrl?: string;
  };

  if (!body.vault || !isAddress(body.vault, { strict: false })) {
    return NextResponse.json({ error: "Valid vault address required." }, { status: 400 });
  }
  if (!body.target || !isAddress(body.target, { strict: false })) {
    return NextResponse.json({ error: "Valid Extruction address required." }, { status: 400 });
  }

  const network = body.network === "mainnet" ? "mainnet" : "sepolia";
  const rpcUrl =
    body.rpcUrl ??
    (network === "mainnet"
      ? process.env.NEXT_PUBLIC_MAINNET_RPC_URL ?? "https://ethereum-rpc.publicnode.com"
      : process.env.NEXT_PUBLIC_SEPOLIA_RPC_URL ?? "https://ethereum-sepolia-rpc.publicnode.com");
  const router = network === "sepolia" ? SEPOLIA_ROUTER : MAINNET_ROUTER;
  const root = repoRoot();
  const tsx = path.join(root, "node_modules/tsx/dist/cli.mjs");

  try {
    const { stdout } = await execFileAsync(
      process.execPath,
      [tsx, "scripts/aqua.ts", "quote", "--json", "--rpc-url", rpcUrl],
      {
        cwd: root,
        timeout: 45_000,
        env: {
          ...process.env,
          VAULT: body.vault,
          EXTRUCTION_TARGET: body.target,
          MAKER_ADDRESS: body.maker && isAddress(body.maker, { strict: false })
            ? body.maker
            : "0x0000000000000000000000000000000000000001",
          SPREAD_BPS: String(body.spreadBps ?? 15),
          BOUND_BPS: String(body.boundBps ?? 100),
          AMOUNT: body.amount ?? "1",
          DIRECTION: body.sharesIn === false ? "asset-to-shares" : "shares-to-asset",
          ROUTER_LAYOUT: body.deployedRouter === false ? "current" : "deployed",
          AQUA_ROUTER: router,
          AQUA_JSON: "1",
        },
      },
    );

    const parsed = JSON.parse(stdout.trim().split("\n").at(-1) ?? "") as Record<string, string>;
    return NextResponse.json(parsed);
  } catch (error) {
    const message = error instanceof Error ? error.message.split("\n")[0] : "Router quote failed.";
    const stderr = error && typeof error === "object" && "stderr" in error
      ? String((error as { stderr?: Buffer | string }).stderr)
      : "";
    return NextResponse.json(
      { error: stderr.trim().split("\n").at(-1) || message },
      { status: 502 },
    );
  }
}
