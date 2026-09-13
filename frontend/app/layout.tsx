import type { Metadata } from "next";

import "./globals.css";

export const metadata: Metadata = {
  title: "Aquifer — Live-rate vault liquidity",
  description: "Build self-custodial ERC-4626 liquidity strategies for 1inch Aqua.",
};

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
