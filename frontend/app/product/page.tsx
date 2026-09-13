import type { Metadata } from "next";

import { ProductStory } from "@/components/ProductStory";

export const metadata: Metadata = {
  title: "Aquifer — Liquidity that never leaves home",
  description:
    "Price ERC-4626 vault shares at the live convertToAssets rate and fill through 1inch Aqua without parking inventory in an AMM.",
};

export default function ProductPage() {
  return <ProductStory />;
}
