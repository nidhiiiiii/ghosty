import { NextResponse } from "next/server";
import { isAddress } from "viem";

import { GRAPH_TOKEN_API, graphApiKey, type TokenApiMeta } from "@/lib/graph";

export const dynamic = "force-dynamic";

async function readToken(contract: string, apiKey: string): Promise<TokenApiMeta | null> {
  const url = new URL(GRAPH_TOKEN_API);
  url.searchParams.set("network", "mainnet");
  url.searchParams.set("contract", contract);
  const response = await fetch(url, {
    headers: { authorization: `Bearer ${apiKey}` },
    cache: "no-store",
  });
  if (!response.ok) return null;
  const payload = (await response.json()) as {
    data?: Array<{
      contract?: string;
      name?: string;
      symbol?: string;
      holders?: number;
      total_transfers?: number;
    }>;
  };
  const row = payload.data?.[0];
  if (!row) return null;
  return {
    contract: row.contract ?? contract,
    name: row.name,
    symbol: row.symbol,
    holders: row.holders,
    totalTransfers: row.total_transfers,
  };
}

export async function GET(request: Request) {
  const apiKey = graphApiKey();
  if (!apiKey) {
    return NextResponse.json({ error: "GRAPH_API_KEY is not set." }, { status: 503 });
  }

  const { searchParams } = new URL(request.url);
  const share = searchParams.get("share") ?? searchParams.get("contract") ?? "";
  const asset = searchParams.get("asset") ?? "";
  if (!isAddress(share, { strict: false })) {
    return NextResponse.json({ error: "Valid share token address required." }, { status: 400 });
  }

  const [shareMeta, assetMeta] = await Promise.all([
    readToken(share, apiKey),
    asset && isAddress(asset, { strict: false }) ? readToken(asset, apiKey) : Promise.resolve(null),
  ]);

  return NextResponse.json({
    product: "token-api",
    share: shareMeta,
    asset: assetMeta,
  });
}
