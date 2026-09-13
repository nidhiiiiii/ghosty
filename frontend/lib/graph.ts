export const GRAPH_GATEWAY = "https://gateway.thegraph.com/api";
export const GRAPH_TOKEN_API = "https://token-api.thegraph.com/v1/evm/tokens";

/** Messari Yield Aggregator deployments on The Graph Network. Same schema, many protocols. */
export const YIELD_SUBGRAPHS = [
  {
    id: "FDLuaz69DbMADuBjJDEcLnTuPnjhZqNbFVrkNiBLGkEg",
    protocol: "Yearn v2",
    schema: "yield-aggregator",
  },
  {
    id: "ANz3TpZdY2syZGQvGA85ANNG7KiSWdPmv55kP4H4sRPJ",
    protocol: "Gamma",
    schema: "yield-aggregator",
  },
  {
    id: "Crag42fFb8PrXnbTjHe1UG5KjgzoiUJbqwzJxZ1W8XNJ",
    protocol: "Ribbon",
    schema: "yield-aggregator",
  },
] as const;

export const STANDARDIZED_VAULTS_QUERY = /* GraphQL */ `
  query AquiferVaults($first: Int!) {
    vaults(first: $first, orderBy: totalValueLockedUSD, orderDirection: desc) {
      id
      name
      symbol
      totalValueLockedUSD
      pricePerShare
      inputToken {
        id
        name
        symbol
        decimals
        lastPriceUSD
      }
      outputToken {
        id
        name
        symbol
      }
      protocol {
        name
        slug
      }
    }
  }
`;

export interface GraphToken {
  id: string;
  name: string;
  symbol: string;
  decimals?: number;
  lastPriceUSD?: string | null;
}

export interface IndexedVault {
  id: string;
  name: string;
  symbol: string;
  protocol: string;
  schema: string;
  subgraphId: string;
  tvlUsd: number;
  pricePerShare: string | null;
  inputToken: GraphToken;
  outputToken: GraphToken | null;
  holders?: number;
  transfers?: number;
}

export interface TokenApiMeta {
  contract: string;
  name?: string;
  symbol?: string;
  holders?: number;
  totalTransfers?: number;
}

export function graphApiKey() {
  return process.env.GRAPH_API_KEY ?? process.env.THE_GRAPH_API_KEY ?? "";
}

export function subgraphEndpoint(subgraphId: string, apiKey: string) {
  return `${GRAPH_GATEWAY}/${apiKey}/subgraphs/id/${subgraphId}`;
}

export function parseUsd(value: string | number | null | undefined) {
  const parsed = typeof value === "number" ? value : Number.parseFloat(value ?? "");
  return Number.isFinite(parsed) ? parsed : 0;
}

export function formatUsd(value: number) {
  if (value >= 1_000_000_000) return `$${(value / 1_000_000_000).toFixed(1)}B`;
  if (value >= 1_000_000) return `$${(value / 1_000_000).toFixed(1)}M`;
  if (value >= 1_000) return `$${(value / 1_000).toFixed(1)}K`;
  if (value <= 0) return "$0";
  return `$${value.toFixed(0)}`;
}

export function formatHolders(value: number) {
  if (value >= 1_000_000) return `${(value / 1_000_000).toFixed(1)}M`;
  if (value >= 1_000) return `${(value / 1_000).toFixed(1)}K`;
  return String(value);
}

/**
 * Decide which Graph-indexed vaults the desk should offer as Aqua inventory.
 * Prefer share-token vaults with real TVL so a maker can actually quote them.
 */
export function rankIndexedVaults(vaults: IndexedVault[], limit = 12): IndexedVault[] {
  return [...vaults]
    .filter((vault) => vault.tvlUsd >= 10_000 && vault.outputToken)
    .sort((left, right) => right.tvlUsd - left.tvlUsd)
    .slice(0, limit);
}

export function findIndexedVault(vaults: IndexedVault[], address: string) {
  const needle = address.toLowerCase();
  return vaults.find((vault) => vault.id.toLowerCase() === needle) ?? null;
}
