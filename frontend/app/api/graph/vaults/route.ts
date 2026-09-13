import { NextResponse } from "next/server";

import {
  STANDARDIZED_VAULTS_QUERY,
  YIELD_SUBGRAPHS,
  graphApiKey,
  parseUsd,
  rankIndexedVaults,
  subgraphEndpoint,
  type GraphToken,
  type IndexedVault,
} from "@/lib/graph";

export const dynamic = "force-dynamic";

interface RawVault {
  id: string;
  name?: string | null;
  symbol?: string | null;
  totalValueLockedUSD?: string | null;
  pricePerShare?: string | null;
  inputToken?: GraphToken | null;
  outputToken?: GraphToken | null;
  protocol?: { name?: string | null; slug?: string | null } | null;
}

async function queryYieldSubgraph(
  subgraphId: string,
  protocol: string,
  apiKey: string,
): Promise<IndexedVault[]> {
  const response = await fetch(subgraphEndpoint(subgraphId, apiKey), {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      query: STANDARDIZED_VAULTS_QUERY,
      variables: { first: 20 },
    }),
    cache: "no-store",
  });
  const payload = (await response.json()) as {
    data?: { vaults?: RawVault[] };
    errors?: { message: string }[];
  };
  if (!response.ok || payload.errors?.length) {
    throw new Error(payload.errors?.[0]?.message ?? `Graph query failed for ${protocol}.`);
  }

  return (payload.data?.vaults ?? []).flatMap((vault) => {
    if (!vault.id || !vault.inputToken) return [];
    return [{
      id: vault.id,
      name: vault.name ?? vault.symbol ?? protocol,
      symbol: vault.symbol ?? "VAULT",
      protocol: vault.protocol?.name ?? protocol,
      schema: "yield-aggregator",
      subgraphId,
      tvlUsd: parseUsd(vault.totalValueLockedUSD),
      pricePerShare: vault.pricePerShare ?? null,
      inputToken: vault.inputToken,
      outputToken: vault.outputToken ?? null,
    }];
  });
}

export async function GET() {
  const apiKey = graphApiKey();
  if (!apiKey) {
    return NextResponse.json(
      {
        error: "Set GRAPH_API_KEY from Subgraph Studio to load live Graph vaults.",
        vaults: [],
        sources: [],
      },
      { status: 503 },
    );
  }

  const settled = await Promise.allSettled(
    YIELD_SUBGRAPHS.map((source) => queryYieldSubgraph(source.id, source.protocol, apiKey)),
  );

  const vaults: IndexedVault[] = [];
  const sources = YIELD_SUBGRAPHS.map((source, index) => {
    const result = settled[index];
    if (result.status === "fulfilled") {
      vaults.push(...result.value);
      return { ...source, ok: true, count: result.value.length };
    }
    return { ...source, ok: false, error: result.reason instanceof Error ? result.reason.message : "query failed" };
  });

  if (!sources.some((source) => source.ok)) {
    return NextResponse.json(
      { error: "The Graph gateway rejected every yield subgraph query.", vaults: [], sources },
      { status: 502 },
    );
  }

  return NextResponse.json({
    vaults: rankIndexedVaults(vaults),
    sources,
    products: ["standardized-subgraphs", "token-api"],
    schema: "https://github.com/messari/subgraphs/blob/master/schema-yield.graphql",
  });
}
