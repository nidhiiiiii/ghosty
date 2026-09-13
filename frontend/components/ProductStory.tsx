"use client";

import Link from "next/link";
import { useEffect, useState } from "react";

import { BrandMark } from "@/components/BrandMark";

type Mode = "amm" | "aquifer";

const STEPS = [
  {
    id: "01",
    title: "Read the vault",
    copy: "Aquifer calls convertToAssets on the ERC-4626. That number is today’s share price, not an AMM curve.",
  },
  {
    id: "02",
    title: "Cut a spread",
    copy: "The maker keeps a few basis points. The quote is still the vault rate, just slightly worse for the taker.",
  },
  {
    id: "03",
    title: "Guard the rate",
    copy: "If someone donates to the vault or the rate jumps, bounds reject the fill. No stale book.",
  },
  {
    id: "04",
    title: "Fill in the wallet",
    copy: "Aqua accounts for the inventory. Shares move only when a resolver takes the other side, atomically.",
  },
] as const;

export function ProductStory() {
  const [mode, setMode] = useState<Mode>("aquifer");
  const [paused, setPaused] = useState(false);
  const [phase, setPhase] = useState(0);
  const [step, setStep] = useState(0);
  const [rate, setRate] = useState(1.0249);

  useEffect(() => {
    const id = window.setInterval(() => {
      setRate((current) => {
        const next = current + 0.00003;
        return next > 1.031 ? 1.02 : next;
      });
    }, 90);
    return () => window.clearInterval(id);
  }, []);

  useEffect(() => {
    const id = window.setInterval(() => setPhase((current) => (current + 1) % 3), 1600);
    return () => window.clearInterval(id);
  }, []);

  useEffect(() => {
    const id = window.setInterval(() => setStep((current) => (current + 1) % STEPS.length), 2800);
    return () => window.clearInterval(id);
  }, []);

  useEffect(() => {
    if (paused) return;
    const id = window.setInterval(() => {
      setMode((current) => (current === "amm" ? "aquifer" : "amm"));
    }, 8000);
    return () => window.clearInterval(id);
  }, [paused]);

  const water = 34 + ((rate - 1.02) / 0.011) * 28;

  return (
    <div className="app story">
      <header className="topbar">
        <Link className="wordmark" href="/">
          <BrandMark />
          <span>Aquifer</span>
        </Link>
        <nav className="nav-links">
          <Link href="/product" aria-current="page">Product</Link>
          <Link href="/">Desk</Link>
        </nav>
        <div className="nav-right">
          <Link className="wallet-button" href="/">Open the desk</Link>
        </div>
      </header>

      <main>
        <section className="story-hero">
          <p className="kicker">What it is</p>
          <h1>Liquidity that<br />never leaves home.</h1>
          <p className="lede">
            Vault shares keep earning. Aquifer prices them at the live ERC-4626 rate and lets
            1inch Aqua fill against inventory that is still sitting in the maker&apos;s wallet.
          </p>
        </section>

        <section className="well-wrap" aria-hidden="true">
          <div className="well">
            <div className="well-soil" />
            <div className="well-water" style={{ height: `${water}%` }}>
              <span className="well-ripple" />
              <span className="well-ripple delay" />
            </div>
            <div className="well-shaft" />
          </div>
          <div className="well-readout">
            <span>convertToAssets</span>
            <strong>1 share → {rate.toFixed(6)}</strong>
          </div>
          <p>The water table is the vault rate. It rises as the vault earns. Aquifer quotes from that line, not from a pool.</p>
        </section>

        <section
          className="story-stage"
          onMouseEnter={() => setPaused(true)}
          onMouseLeave={() => setPaused(false)}
        >
          <div className="stage-head">
            <div>
              <p className="kicker">The difference</p>
              <h2>Same shares. Different book.</h2>
            </div>
            <div className="stage-tabs" role="tablist" aria-label="Liquidity model">
              <button
                type="button"
                role="tab"
                aria-selected={mode === "amm"}
                className={mode === "amm" ? "active" : ""}
                onClick={() => {
                  setPaused(true);
                  setMode("amm");
                }}
              >
                AMM pool
              </button>
              <button
                type="button"
                role="tab"
                aria-selected={mode === "aquifer"}
                className={mode === "aquifer" ? "active" : ""}
                onClick={() => {
                  setPaused(true);
                  setMode("aquifer");
                }}
              >
                Aquifer
              </button>
            </div>
          </div>

          <div className={`stage-board ${mode} phase-${phase}`}>
            <article className="node">
              <span>Maker wallet</span>
              <strong>100 aqV</strong>
              <div className="share-stack">
                <i /><i /><i /><i />
              </div>
              <small>{mode === "amm" ? "Deposited" : "Still earning"}</small>
            </article>
            <article className="node mid">
              <span>{mode === "amm" ? "Shared pool" : "Live vault rate"}</span>
              {mode === "amm" ? <div className="pool" /> : <div className="table"><b /></div>}
              <strong>{mode === "amm" ? "Pool price" : rate.toFixed(4)}</strong>
              <small>{mode === "amm" ? "Custody left the wallet" : "Quoted, not deposited"}</small>
            </article>
            <article className="node">
              <span>{mode === "amm" ? "LP position" : "Aqua fill"}</span>
              <strong>{mode === "amm" ? "lpToken" : phase === 2 ? "102.35 USDC" : "waiting"}</strong>
              <div className={`fill-mark ${mode === "aquifer" && phase === 2 ? "hot" : ""}`} />
              <small>{mode === "amm" ? "Exit the pool to spend" : "Atomic, then gone"}</small>
            </article>
          </div>
          <p className="stage-caption">
            {mode === "amm"
              ? "An AMM needs the shares in the pool before anyone can trade them. Yield and custody move with the deposit."
              : "Aquifer leaves the shares where they are. Aqua can still quote them because SwapVM reads the vault and applies the maker’s spread and bounds."}
          </p>
        </section>

        <section className="story-steps">
          <p className="kicker">How a quote is born</p>
          <h2>Four checks. One instruction.</h2>
          <div className="step-track" aria-hidden="true">
            <span className="step-pulse" style={{ left: `${step * 25 + 12.5}%` }} />
          </div>
          <ol>
            {STEPS.map((item, index) => (
              <li key={item.id} className={index === step ? "on" : ""}>
                <button type="button" onClick={() => setStep(index)}>
                  <em>{item.id}</em>
                  <strong>{item.title}</strong>
                  <p>{item.copy}</p>
                </button>
              </li>
            ))}
          </ol>
        </section>

        <section className="story-cta">
          <h2>Price a vault.</h2>
          <p>The desk discovers vaults from The Graph&apos;s Messari yield subgraphs, reads the live convertToAssets rate from RPC, builds the SwapVM instruction, and copies a ship command. It does not broadcast strategy calldata from the browser.</p>
          <Link className="btn-launch" href="/">Open the desk</Link>
        </section>
      </main>

      <footer className="site-footer">
        <span>Proof of concept — not audited production software</span>
        <span>SwapVM Extruction · 1inch Aqua · The Graph</span>
      </footer>
    </div>
  );
}
