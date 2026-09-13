"use client";

import Link from "next/link";
import { useEffect, useMemo, useRef, useState } from "react";
import { isAddress } from "viem";

import { BrandMark } from "@/components/BrandMark";

import {
  AQUA_ADDRESS,
  aquaRouterFor,
  buildInstruction,
  buildPreview,
  compactAddress,
  formatRate,
  MAX_BOUND_BPS,
  networks,
  rateBounds,
  readVault,
  SEPOLIA_EXTRUCTION,
  SEPOLIA_VAULT,
  type NetworkKey,
  type VaultMetadata,
} from "@/lib/aquifer";
import {
  findIndexedVault,
  formatHolders,
  formatUsd,
  type IndexedVault,
  type TokenApiMeta,
} from "@/lib/graph";

const DEFAULT_VAULT = {
  mainnet: "0x83F20F44975D03b1b09e64809B757c47f942BEeA",
  sepolia: SEPOLIA_VAULT,
  local: "",
} as const;

type LoadState =
  | { status: "empty" }
  | { status: "loading" }
  | { status: "error"; message: string }
  | { status: "ready"; data: VaultMetadata };

const NETWORK_HINT: Record<NetworkKey, string> = {
  mainnet: "Mainnet",
  sepolia: "Testnet",
  local: "Anvil",
};

function NetworkMenu({
  value,
  onChange,
}: {
  value: NetworkKey;
  onChange: (next: NetworkKey) => void;
}) {
  const [open, setOpen] = useState(false);
  const rootRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!open) return;
    function onPointer(event: MouseEvent) {
      if (!rootRef.current?.contains(event.target as Node)) setOpen(false);
    }
    function onKey(event: KeyboardEvent) {
      if (event.key === "Escape") setOpen(false);
    }
    document.addEventListener("mousedown", onPointer);
    document.addEventListener("keydown", onKey);
    return () => {
      document.removeEventListener("mousedown", onPointer);
      document.removeEventListener("keydown", onKey);
    };
  }, [open]);

  return (
    <div className={`network-menu${open ? " open" : ""}`} ref={rootRef}>
      <button
        type="button"
        className="network-trigger"
        aria-label="Network"
        aria-haspopup="listbox"
        aria-expanded={open}
        onClick={() => setOpen((current) => !current)}
      >
        <span className={`net-dot ${value}`} />
        {networks[value].label}
        <svg width="10" height="6" viewBox="0 0 10 6" fill="none" aria-hidden="true">
          <path d="M1 1l4 4 4-4" stroke="currentColor" strokeWidth="1.2" />
        </svg>
      </button>
      {open ? (
        <div className="network-panel" role="listbox" aria-label="Network">
          {(Object.keys(networks) as NetworkKey[]).map((key) => (
            <button
              key={key}
              type="button"
              role="option"
              aria-selected={key === value}
              className={key === value ? "active" : ""}
              onClick={() => {
                onChange(key);
                setOpen(false);
              }}
            >
              <span className={`net-dot ${key}`} />
              <span>
                <strong>{networks[key].label}</strong>
                <small>{NETWORK_HINT[key]} · {networks[key].chain.id}</small>
              </span>
              {key === value ? <span className="picked">✓</span> : null}
            </button>
          ))}
        </div>
      ) : null}
    </div>
  );
}

function errorMessage(error: unknown) {
  if (error instanceof Error) {
    if (error.message.includes("HTTP request failed")) return "The RPC did not answer. Try another network or RPC URL.";
    if (error.message.includes("returned no data")) return "This contract does not expose the expected ERC-4626 metadata.";
    return error.message.split("\n")[0];
  }
  return "Vault detection failed.";
}

export function AquiferApp() {
  const [network, setNetwork] = useState<NetworkKey>("sepolia");
  const [vault, setVault] = useState<string>(DEFAULT_VAULT.sepolia);
  const [target, setTarget] = useState<string>(process.env.NEXT_PUBLIC_EXTRUCTION_ADDRESS ?? SEPOLIA_EXTRUCTION);
  const [spreadBps, setSpreadBps] = useState(15);
  const [boundBps, setBoundBps] = useState(100);
  const [amount, setAmount] = useState("100");
  const [sharesIn, setSharesIn] = useState(true);
  const [deployedRouter, setDeployedRouter] = useState(true);
  const [loadState, setLoadState] = useState<LoadState>({ status: "empty" });
  const [account, setAccount] = useState("");
  const [walletChain, setWalletChain] = useState<number | null>(null);
  const [walletError, setWalletError] = useState("");
  const [copied, setCopied] = useState(false);
  const [onChainOut, setOnChainOut] = useState("");
  const [onChainHash, setOnChainHash] = useState("");
  const [onChainError, setOnChainError] = useState("");
  const [onChainBusy, setOnChainBusy] = useState(false);
  const [indexedVaults, setIndexedVaults] = useState<IndexedVault[]>([]);
  const [graphStatus, setGraphStatus] = useState<"loading" | "ready" | "error">("loading");
  const [graphError, setGraphError] = useState("");
  const [tokenMeta, setTokenMeta] = useState<{ share: TokenApiMeta | null; asset: TokenApiMeta | null } | null>(null);

  useEffect(() => {
    let active = true;
    fetch("/api/graph/vaults")
      .then(async (response) => {
        const payload = (await response.json()) as { vaults?: IndexedVault[]; error?: string };
        if (!active) return;
        setIndexedVaults(payload.vaults ?? []);
        if (!response.ok) {
          setGraphStatus("error");
          setGraphError(payload.error ?? "The Graph index is unavailable.");
          return;
        }
        setGraphStatus("ready");
        setGraphError("");
      })
      .catch(() => {
        if (!active) return;
        setGraphStatus("error");
        setGraphError("The Graph index is unavailable.");
      });
    return () => {
      active = false;
    };
  }, []);

  useEffect(() => {
    const value = vault.trim();
    if (!value || !isAddress(value, { strict: false })) return;

    let active = true;
    const timeout = window.setTimeout(async () => {
      setLoadState({ status: "loading" });
      try {
        const data = await readVault(network, value);
        if (active) setLoadState({ status: "ready", data });
      } catch (error) {
        if (active) setLoadState({ status: "error", message: errorMessage(error) });
      }
    }, 350);

    return () => {
      active = false;
      window.clearTimeout(timeout);
    };
  }, [network, vault]);

  const displayedLoadState = useMemo<LoadState>(() => {
    const value = vault.trim();
    if (!value) return { status: "empty" };
    if (!isAddress(value, { strict: false })) {
      return { status: "error", message: "Enter a valid EVM vault address." };
    }
    return loadState;
  }, [loadState, vault]);

  const computed = useMemo(() => {
    if (displayedLoadState.status !== "ready") return null;
    try {
      const quote = buildPreview(displayedLoadState.data, amount, sharesIn, spreadBps);
      const bounds = rateBounds(displayedLoadState.data.rate, boundBps);
      const instruction = buildInstruction(
        target,
        displayedLoadState.data,
        spreadBps,
        boundBps,
        deployedRouter,
      );
      return { quote, bounds, instruction, error: "" };
    } catch (error) {
      return { quote: null, bounds: null, instruction: null, error: errorMessage(error) };
    }
  }, [amount, boundBps, deployedRouter, displayedLoadState, sharesIn, spreadBps, target]);

  const selectedNetwork = networks[network];
  const walletReady = account && walletChain === selectedNetwork.chain.id;
  const vaultReady = displayedLoadState.status === "ready" ? displayedLoadState.data : null;
  const graphVault = vaultReady ? findIndexedVault(indexedVaults, vaultReady.vault) : null;

  useEffect(() => {
    if (!vaultReady || network !== "mainnet") {
      setTokenMeta(null);
      return;
    }
    let active = true;
    const params = new URLSearchParams({
      share: vaultReady.vault,
      asset: vaultReady.asset,
    });
    fetch(`/api/graph/token?${params}`)
      .then(async (response) => {
        const payload = (await response.json()) as {
          share?: TokenApiMeta | null;
          asset?: TokenApiMeta | null;
        };
        if (active && response.ok) setTokenMeta({ share: payload.share ?? null, asset: payload.asset ?? null });
      })
      .catch(() => {
        if (active) setTokenMeta(null);
      });
    return () => {
      active = false;
    };
  }, [network, vaultReady]);

  function pickIndexedVault(next: IndexedVault) {
    setNetwork("mainnet");
    setVault(next.id);
  }

  async function connectWallet() {
    setWalletError("");
    if (!window.ethereum) {
      setWalletError("No injected wallet found. Install a browser wallet to continue.");
      return;
    }
    try {
      const accounts = (await window.ethereum.request({ method: "eth_requestAccounts" })) as string[];
      const chainHex = (await window.ethereum.request({ method: "eth_chainId" })) as string;
      setAccount(accounts[0] ?? "");
      setWalletChain(Number.parseInt(chainHex, 16));
    } catch (error) {
      setWalletError(errorMessage(error));
    }
  }

  async function switchNetwork() {
    if (!window.ethereum) return;
    setWalletError("");
    try {
      await window.ethereum.request({
        method: "wallet_switchEthereumChain",
        params: [{ chainId: `0x${selectedNetwork.chain.id.toString(16)}` }],
      });
      setWalletChain(selectedNetwork.chain.id);
    } catch (error) {
      setWalletError(errorMessage(error));
    }
  }

  async function runOnChainQuote() {
    if (displayedLoadState.status !== "ready") return;
    setOnChainBusy(true);
    setOnChainError("");
    try {
      const response = await fetch("/api/aqua-quote", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          network,
          vault: displayedLoadState.data.vault,
          target,
          amount,
          sharesIn,
          spreadBps,
          boundBps,
          deployedRouter,
          maker: account || undefined,
        }),
      });
      const payload = (await response.json()) as {
        formattedOut?: string;
        orderHash?: string;
        error?: string;
      };
      if (!response.ok || !payload.formattedOut) {
        throw new Error(payload.error ?? "SwapVM router quote failed.");
      }
      setOnChainOut(payload.formattedOut);
      setOnChainHash(payload.orderHash ?? "");
    } catch (error) {
      setOnChainOut("");
      setOnChainHash("");
      setOnChainError(errorMessage(error));
    } finally {
      setOnChainBusy(false);
    }
  }

  async function copyShipCommand() {
    if (displayedLoadState.status !== "ready" || !computed?.instruction) return;
    const command = [
      `VAULT=${displayedLoadState.data.vault}`,
      `EXTRUCTION_TARGET=${target}`,
      `AQUA_ROUTER=${aquaRouterFor(network)}`,
      `SPREAD_BPS=${spreadBps}`,
      `BOUND_BPS=${boundBps}`,
      `npm run aqua -- ship --rpc-url '<RPC_URL>'`,
    ].join(" ");
    await navigator.clipboard.writeText(command);
    setCopied(true);
    window.setTimeout(() => setCopied(false), 1600);
  }

  return (
    <div className="app">
      <header className="topbar">
        <Link className="wordmark" href="/">
          <BrandMark />
          <span>Aquifer</span>
        </Link>
        <nav className="nav-links">
          <Link href="/product">Product</Link>
          <a href="#desk" aria-current="page">Desk</a>
          <a href="#instruction">Instruction</a>
        </nav>
        <div className="nav-right">
          <NetworkMenu
            value={network}
            onChange={(next) => {
              setNetwork(next);
              if (DEFAULT_VAULT[next]) setVault(DEFAULT_VAULT[next]);
              if (next === "sepolia") setTarget(SEPOLIA_EXTRUCTION);
            }}
          />
          <button className={`wallet-button${account ? " connected" : ""}`} onClick={connectWallet}>
            {account ? compactAddress(account) : (
              <>
                <span className="connect-full">Connect wallet</span>
                <span className="connect-short">Connect</span>
              </>
            )}
          </button>
        </div>
      </header>

      {vaultReady && (
        <div className="tape" aria-live="polite">
          <span>{selectedNetwork.label}</span>
          <span>{vaultReady.symbol} → {vaultReady.assetSymbol} <b>{formatRate(vaultReady)}</b></span>
          <span>Spread <b>{spreadBps} bps</b></span>
          <span>Guard <b>±{(boundBps / 100).toFixed(2)}%</b></span>
        </div>
      )}

      <main>
        <section className="hero">
          <p className="kicker">1inch Aqua · The Graph</p>
          <h1>Still earning.<br />Already liquid.</h1>
          <p className="lede">
            Price any ERC-4626 share from its live convertToAssets rate. Maker funds never leave
            the wallet until an Aqua resolver takes the other side.
          </p>
          <div className="hero-actions">
            <a className="btn-launch" href="#desk">Open the desk</a>
            <a className="btn-ghost" href="#instruction">Read the instruction</a>
          </div>
          <dl className="proof">
            <div>
              <dt>Pricing</dt>
              <dd>ERC-4626</dd>
            </div>
            <div>
              <dt>Custody</dt>
              <dd>Self-held</dd>
            </div>
            <div>
              <dt>Settlement</dt>
              <dd>1inch Aqua</dd>
            </div>
            <div>
              <dt>Index</dt>
              <dd>The Graph</dd>
            </div>
          </dl>
        </section>

        <section className="desk" id="desk">
          <div className="pane">
            <div className="pane-kicker">
              <span>01 / Vault</span>
              <span className="chip">{selectedNetwork.label}</span>
            </div>
            <div className="step">
              <span>01</span>
              <div>
                <h2>Choose a vault</h2>
                <p>The Graph lists live yield vaults. Aquifer then reads convertToAssets on {selectedNetwork.label}.</p>
              </div>
            </div>

            <div className="graph-index">
              <div className="field-label">Indexed by The Graph</div>
              {graphStatus === "loading" && <p className="graph-hint">Querying Messari yield subgraphs…</p>}
              {graphStatus === "error" && <p className="graph-hint warn">{graphError}</p>}
              {graphStatus === "ready" && indexedVaults.length === 0 && (
                <p className="graph-hint">No vaults passed the TVL filter.</p>
              )}
              {indexedVaults.length > 0 && (
                <div className="vault-picks" role="list">
                  {indexedVaults.map((item) => {
                    const selected = vault.trim().toLowerCase() === item.id.toLowerCase();
                    return (
                      <button
                        key={`${item.subgraphId}-${item.id}`}
                        type="button"
                        role="listitem"
                        className={selected ? "active" : ""}
                        onClick={() => pickIndexedVault(item)}
                      >
                        <strong>{item.symbol}</strong>
                        <small>{item.protocol}</small>
                        <span>{formatUsd(item.tvlUsd)}</span>
                      </button>
                    );
                  })}
                </div>
              )}
            </div>

            <label className="field-label" htmlFor="vault">Vault address</label>
            <div className={`address-field ${displayedLoadState.status}`}>
              <input
                id="vault"
                spellCheck={false}
                value={vault}
                onChange={(event) => setVault(event.target.value)}
                placeholder="0x…"
              />
              {displayedLoadState.status === "loading" && <span className="spinner" aria-label="Loading" />}
              {displayedLoadState.status === "ready" && <span className="check">✓</span>}
            </div>

            {displayedLoadState.status === "empty" && (
              <div className="state-card empty-state">Pick a Graph-indexed vault or paste an ERC-4626 address.</div>
            )}
            {displayedLoadState.status === "loading" && (
              <div className="metadata-card skeleton" aria-label="Loading vault metadata">
                <span /><span /><span />
              </div>
            )}
            {displayedLoadState.status === "error" && (
              <div className="state-card error-state">{displayedLoadState.message}</div>
            )}
            {vaultReady && (
              <div className="metadata-card">
                <div className="token-lockup">
                  <span className="token-icon">{vaultReady.symbol.slice(0, 2)}</span>
                  <div>
                    <strong>{vaultReady.name}</strong>
                    <small>{vaultReady.symbol} · {vaultReady.shareDecimals} decimals</small>
                  </div>
                  <span className="verified">ERC-4626</span>
                </div>
                <div className="rate-row">
                  <span>1 {vaultReady.symbol}</span>
                  <span className="rate-arrow">→</span>
                  <strong>{formatRate(vaultReady)} {vaultReady.assetSymbol}</strong>
                </div>
                <div className="asset-row">
                  <span>Underlying</span>
                  <code>{compactAddress(vaultReady.asset)}</code>
                  <span>{vaultReady.assetName}</span>
                </div>
                {(graphVault || tokenMeta?.share) && (
                  <div className="asset-row graph-row">
                    <span>The Graph</span>
                    {graphVault && <span>{graphVault.protocol} · {formatUsd(graphVault.tvlUsd)} TVL</span>}
                    {tokenMeta?.share?.holders != null && (
                      <span>{formatHolders(tokenMeta.share.holders)} holders</span>
                    )}
                  </div>
                )}
              </div>
            )}

            <div className="rule" />
            <div className="pane-kicker"><span>02 / Quote</span></div>
            <div className="step">
              <span>02</span>
              <div>
                <h2>Shape the quote</h2>
                <p>Set maker spread and a circuit breaker around today&apos;s rate.</p>
              </div>
            </div>

            <div className="control-grid">
              <label>
                <span>Maker spread <i>{(spreadBps / 100).toFixed(2)}%</i></span>
                <input
                  type="range"
                  min="0"
                  max="500"
                  step="1"
                  value={spreadBps}
                  onChange={(event) => setSpreadBps(Number(event.target.value))}
                />
                <small>0%</small><small>5%</small>
              </label>
              <label>
                <span>Rate guard <i>±{(boundBps / 100).toFixed(2)}%</i></span>
                <input
                  type="range"
                  min="1"
                  max={MAX_BOUND_BPS}
                  step="1"
                  value={boundBps}
                  onChange={(event) => setBoundBps(Number(event.target.value))}
                />
                <small>tight</small><small>±1%</small>
              </label>
            </div>

            <label className="field-label" htmlFor="target">Extruction target</label>
            <input
              className="plain-input"
              id="target"
              spellCheck={false}
              value={target}
              onChange={(event) => setTarget(event.target.value)}
              placeholder="Deploy the target, then paste 0x…"
            />
            <label className="check-line">
              <input
                type="checkbox"
                checked={deployedRouter}
                onChange={(event) => setDeployedRouter(event.target.checked)}
              />
              Encode for deployed Aqua router (required on live Aqua; opcode 0x20)
            </label>
          </div>

          <aside className="pane ticket">
            <div className="pane-kicker">
              <span>Ticket</span>
              <span className="chip">{network === "sepolia" ? "Sepolia SwapVM" : "Preview"}</span>
            </div>

            {displayedLoadState.status !== "ready" ? (
              <div className="preview-empty">
                <h3>No vault loaded.</h3>
                <p>Pick a Graph-indexed vault or paste an ERC-4626 address. The live rate and SwapVM instruction open on this ticket.</p>
              </div>
            ) : (
              <>
                <div className="flow-card">
                  <div className="flow-top">
                    <button className={sharesIn ? "active" : ""} onClick={() => setSharesIn(true)}>
                      Sell shares
                    </button>
                    <button className={!sharesIn ? "active" : ""} onClick={() => setSharesIn(false)}>
                      Buy shares
                    </button>
                  </div>
                  <label>
                    You send
                    <div className="amount-row">
                      <input value={amount} inputMode="decimal" onChange={(event) => setAmount(event.target.value)} />
                      <strong>{sharesIn ? displayedLoadState.data.symbol : displayedLoadState.data.assetSymbol}</strong>
                    </div>
                  </label>
                  <div className="flow-arrow">↓</div>
                  <label>
                    Quoted output
                    <div className="amount-row output">
                      <span>{computed?.quote?.formattedOut ?? "—"}</span>
                      <strong>{sharesIn ? displayedLoadState.data.assetSymbol : displayedLoadState.data.symbol}</strong>
                    </div>
                  </label>
                  {computed?.error && <p className="inline-error">{computed.error}</p>}
                  {onChainOut && (
                    <p className="inline-ok">
                      SwapVM router: {onChainOut}
                      {onChainHash ? ` · ${compactAddress(onChainHash)}` : ""}
                    </p>
                  )}
                  {onChainError && <p className="inline-error">{onChainError}</p>}
                </div>

                <dl className="strategy-facts">
                  <div><dt>Pricing</dt><dd>vault.convertToAssets</dd></div>
                  <div><dt>Index</dt><dd>{graphVault ? graphVault.protocol : "RPC + The Graph"}</dd></div>
                  {graphVault && <div><dt>Graph TVL</dt><dd>{formatUsd(graphVault.tvlUsd)}</dd></div>}
                  {tokenMeta?.share?.holders != null && (
                    <div><dt>Share holders</dt><dd>{formatHolders(tokenMeta.share.holders)}</dd></div>
                  )}
                  <div><dt>Spread</dt><dd>{spreadBps} bps</dd></div>
                  <div><dt>Min rate</dt><dd>{computed?.bounds?.minRate.toString() ?? "—"}</dd></div>
                  <div><dt>Max rate</dt><dd>{computed?.bounds?.maxRate.toString() ?? "—"}</dd></div>
                  <div><dt>Settlement</dt><dd>Self-custodial</dd></div>
                  <div><dt>SwapVM router</dt><dd>{compactAddress(aquaRouterFor(network))}</dd></div>
                </dl>

                <div className="bytecode" id="instruction">
                  <span>Extruction instruction</span>
                  <code>{computed?.instruction ?? "Add a deployed target address to encode."}</code>
                </div>

                <div className="action-stack">
                  <button className="primary" disabled={onChainBusy || !computed?.instruction} onClick={runOnChainQuote}>
                    {onChainBusy ? "Quoting SwapVM…" : "Quote via SwapVM router"}
                  </button>
                  {!account && <button className="primary" onClick={connectWallet}>Connect maker wallet</button>}
                  {account && !walletReady && <button className="primary" onClick={switchNetwork}>Switch to {selectedNetwork.label}</button>}
                  {walletReady && (
                    <button className="primary" disabled={!computed?.instruction} onClick={copyShipCommand}>
                      {copied ? "Command copied ✓" : "Copy safe ship command"}
                    </button>
                  )}
                  <p>
                    Quote hits the live SwapVM router
                    ({compactAddress(aquaRouterFor(network))}). The shipped Sepolia
                    strategy is 15 bps / ±1% on this vault. Fills still need a resolver KYC NFT.
                  </p>
                </div>
              </>
            )}
            {walletError && <div className="state-card error-state wallet-error">{walletError}</div>}
          </aside>
        </section>
      </main>

      <footer className="site-footer">
        <span>Powered by SwapVM — © Degensoft Ltd 2025</span>
        <span>Aqua <code>{compactAddress(AQUA_ADDRESS)}</code> · Router <code>{compactAddress(aquaRouterFor(network))}</code></span>
      </footer>
    </div>
  );
}
