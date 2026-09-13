import { NextResponse } from "next/server";

export const dynamic = "force-dynamic";

export async function POST(request: Request) {
  const upstream = process.env.LOCAL_RPC_URL ?? "http://127.0.0.1:8545";

  try {
    const response = await fetch(upstream, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: await request.text(),
      cache: "no-store",
    });

    return new Response(await response.text(), {
      status: response.status,
      headers: { "content-type": response.headers.get("content-type") ?? "application/json" },
    });
  } catch {
    return NextResponse.json(
      { jsonrpc: "2.0", id: null, error: { code: -32_603, message: "Local RPC is unavailable" } },
      { status: 502 },
    );
  }
}
