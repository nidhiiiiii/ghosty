"use client";

import { useEffect, useMemo, useState } from "react";
import { isAddress } from "viem";

import {
  AQUA_ADDRESS,
  AQUA_ROUTER_ADDRESS,
  buildInstruction,
  buildPreview,
  compactAddress,
  formatRate,
  networks,
  rateBounds,
  readVault,
  type NetworkKey,
  type VaultMetadata,
} from "@/lib/aquifer";

const DEFAULT_VAULT = "0x83F20F44975D03b1b09e64809B757c47f942BEeA";

type LoadState =
  | { status: "empty" }
  | { status: "loading" }
  | { status: "error"; message: string }
  | { status: "ready"; data: VaultMetadata };

function errorMessage(error: unknown) {
  if (error instanceof Error) {
    if (error.message.includes("HTTP request failed")) return "The RPC did not answer. Try another network or RPC URL.";
    if (error.message.includes("returned no data")) return "This contract does not expose the expected ERC-4626 metadata.";
    return error.message.split("\n")[0];
  }
  return "Vault detection failed.";
}

export function AquiferApp() {
  const [network, setNetwork] = useState<NetworkKey>("mainnet");
  const [vault, setVault] = useState(DEFAULT_VAULT);
  const [target, setTarget] = useState(process.env.NEXT_PUBLIC_EXTRUCTION_ADDRESS ?? "");
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

  async function copyShipCommand() {
    if (displayedLoadState.status !== "ready" || !computed?.instruction) return;
    const command = [
      `VAULT=${displayedLoadState.data.vault}`,
      `EXTRUCTION_TARGET=${target}`,
      `SPREAD_BPS=${spreadBps}`,
      `BOUND_BPS=${boundBps}`,
      `npm run aqua -- ship --rpc-url '<RPC_URL>'`,
    ].join(" ");
    await navigator.clipboard.writeText(command);
    setCopied(true);
    window.setTimeout(() => setCopied(false), 1600);
  }

  return (
    <main>
      <nav>
        <a className="brand" href="#">
          <span className="brand-mark">A</span>
          <span>Aquifer</span>
        </a>
        <div className="nav-right">
          <span className="network-dot" />
          <select
            aria-label="Network"
            value={network}
            onChange={(event) => setNetwork(event.target.value as NetworkKey)}
          >
            {Object.entries(networks).map(([key, item]) => (
              <option key={key} value={key}>
                {item.label}
              </option>
            ))}
          </select>
          <button className="wallet-button" onClick={connectWallet}>
            {account ? compactAddress(account) : "Connect wallet"}
          </button>
        </div>
      </nav>

      <section className="hero">
        <div className="eyebrow"><span /> LIVE-RATE LIQUIDITY</div>
        <h1>Your vault earns.<br /><em>Your liquidity keeps up.</em></h1>
        <p>
          Price any ERC-4626 share from its on-chain exchange rate. Maker funds stay in their wallet,
          ready for atomic fills through 1inch Aqua.
        </p>
      </section>

      <section className="workspace">
        <div className="panel strategy-panel">
          <div className="step">
            <span>01</span>
            <div>
              <h2>Choose a vault</h2>
              <p>Aquifer reads ERC-4626 metadata directly from {selectedNetwork.label}.</p>
            </div>
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
            <div className="state-card empty-state">Paste a vault address to inspect its live conversion rate.</div>
          )}
          {displayedLoadState.status === "loading" && (
            <div className="metadata-card skeleton" aria-label="Loading vault metadata">
              <span /><span /><span />
            </div>
          )}
          {displayedLoadState.status === "error" && (
            <div className="state-card error-state">{displayedLoadState.message}</div>
          )}
          {displayedLoadState.status === "ready" && (
            <div className="metadata-card">
              <div className="token-lockup">
                <span className="token-icon">{displayedLoadState.data.symbol.slice(0, 2)}</span>
                <div>
                  <strong>{displayedLoadState.data.name}</strong>
                  <small>{displayedLoadState.data.symbol} · {displayedLoadState.data.shareDecimals} decimals</small>
                </div>
                <span className="verified">ERC-4626</span>
              </div>
              <div className="rate-row">
                <span>1 {displayedLoadState.data.symbol}</span>
                <span className="rate-arrow">→</span>
                <strong>{formatRate(displayedLoadState.data)} {displayedLoadState.data.assetSymbol}</strong>
              </div>
              <div className="asset-row">
                <span>Underlying</span>
                <code>{compactAddress(displayedLoadState.data.asset)}</code>
                <span>{displayedLoadState.data.assetName}</span>
              </div>
            </div>
          )}

          <div className="divider" />
          <div className="step compact-step">
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
                max="1000"
                step="1"
                value={boundBps}
                onChange={(event) => setBoundBps(Number(event.target.value))}
              />
              <small>tight</small><small>wide</small>
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
            Encode for deployed Aqua router (v1.0.2, opcode 0x20)
          </label>
        </div>

        <aside className="panel preview-panel">
          <div className="preview-heading">
            <span>STRATEGY PREVIEW</span>
            <i>Preview only</i>
          </div>

          {displayedLoadState.status !== "ready" ? (
            <div className="preview-empty">
              <div className="rings"><span>A</span></div>
              <h3>Waiting for a vault</h3>
              <p>A deterministic strategy preview will appear once rate detection succeeds.</p>
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
              </div>

              <dl className="strategy-facts">
                <div><dt>Pricing</dt><dd>vault.convertToAssets</dd></div>
                <div><dt>Spread</dt><dd>{spreadBps} bps</dd></div>
                <div><dt>Min rate</dt><dd>{computed?.bounds?.minRate.toString() ?? "—"}</dd></div>
                <div><dt>Max rate</dt><dd>{computed?.bounds?.maxRate.toString() ?? "—"}</dd></div>
                <div><dt>Settlement</dt><dd>Self-custodial</dd></div>
              </dl>

              <div className="bytecode">
                <span>EXTRUCTION INSTRUCTION</span>
                <code>{computed?.instruction ?? "Add a deployed target address to encode."}</code>
              </div>

              <div className="action-stack">
                {!account && <button className="primary" onClick={connectWallet}>Connect maker wallet</button>}
                {account && !walletReady && <button className="primary" onClick={switchNetwork}>Switch to {selectedNetwork.label}</button>}
                {walletReady && (
                  <button className="primary" disabled={!computed?.instruction} onClick={copyShipCommand}>
                    {copied ? "Command copied ✓" : "Copy safe ship command"}
                  </button>
                )}
                <p>
                  Shipping uses the official SDK in the repository CLI. The browser does not submit unreviewed
                  strategy calldata. Mainnet fills additionally require a resolver KYC NFT.
                </p>
              </div>
            </>
          )}
          {walletError && <div className="state-card error-state wallet-error">{walletError}</div>}
        </aside>
      </section>

      <footer>
        <span>Powered by SwapVM — © Degensoft Ltd 2025</span>
        <span>Aqua <code>{compactAddress(AQUA_ADDRESS)}</code> · Router <code>{compactAddress(AQUA_ROUTER_ADDRESS)}</code></span>
      </footer>
    </main>
  );
}
