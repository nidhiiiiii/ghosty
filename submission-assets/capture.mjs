import { spawn } from "node:child_process";
import { mkdir } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const root = path.dirname(fileURLToPath(import.meta.url));
await mkdir(root, { recursive: true });

function shot({ url, file, width, height, delayMs = 2500 }) {
  return new Promise((resolve, reject) => {
    const out = path.join(root, file);
    const child = spawn(
      chrome,
      [
        "--headless=new",
        "--disable-gpu",
        "--hide-scrollbars",
        "--no-first-run",
        "--no-default-browser-check",
        `--window-size=${width},${height}`,
        `--virtual-time-budget=${delayMs + 2000}`,
        `--screenshot=${out}`,
        url,
      ],
      { stdio: "inherit" },
    );
    child.on("exit", (code) => {
      if (code === 0) resolve(out);
      else reject(new Error(`Chrome exited ${code} for ${file}`));
    });
  });
}

const jobs = [
  {
    url: `file://${path.join(root, "logo.html")}`,
    file: "logo-512.png",
    width: 512,
    height: 512,
    delayMs: 400,
  },
  {
    url: `file://${path.join(root, "cover.html")}`,
    file: "cover-16x9.png",
    width: 1600,
    height: 900,
    delayMs: 1500,
  },
  {
    url: "http://127.0.0.1:3000/",
    file: "screenshot-01-hero.png",
    width: 1440,
    height: 900,
    delayMs: 4000,
  },
  {
    url: "http://127.0.0.1:3000/#desk",
    file: "screenshot-02-desk.png",
    width: 1440,
    height: 980,
    delayMs: 5000,
  },
  {
    url: "http://127.0.0.1:3000/product",
    file: "screenshot-03-product.png",
    width: 1440,
    height: 900,
    delayMs: 4000,
  },
  {
    url: "http://127.0.0.1:3000/product",
    file: "screenshot-04-product-story.png",
    width: 1440,
    height: 1400,
    delayMs: 4500,
  },
];

for (const job of jobs) {
  console.log("capturing", job.file);
  await shot(job);
}

console.log("done");
