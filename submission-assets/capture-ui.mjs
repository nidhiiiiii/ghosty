import puppeteer from "/tmp/aquifer-shots/node_modules/puppeteer-core/lib/puppeteer/puppeteer-core.js";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.dirname(fileURLToPath(import.meta.url));
const chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";

const browser = await puppeteer.launch({
  executablePath: chrome,
  headless: "new",
  args: ["--hide-scrollbars", "--disable-gpu", "--no-first-run"],
});

const page = await browser.newPage();
await page.setViewport({ width: 1440, height: 920, deviceScaleFactor: 2 });

async function open(url) {
  await page.goto(url, { waitUntil: "networkidle0", timeout: 30000 });
  await page.waitForSelector(".app", { timeout: 15000 });
  await page.evaluate(() => {
    document.documentElement.style.scrollBehavior = "auto";
  });
  await new Promise((resolve) => setTimeout(resolve, 2800));
}

async function shotViewport(file) {
  const out = path.join(root, file);
  await page.screenshot({ path: out, type: "png" });
  console.log("wrote", out);
}

async function shotElement(selector, file) {
  const handle = await page.$(selector);
  if (!handle) throw new Error(`missing ${selector}`);
  const out = path.join(root, file);
  await handle.screenshot({ path: out, type: "png" });
  console.log("wrote", out, selector);
}

await open("http://127.0.0.1:3000/");
await shotViewport("screenshot-01-hero.png");
await shotElement(".desk", "screenshot-02-desk.png");

await open("http://127.0.0.1:3000/product");
await shotViewport("screenshot-03-product.png");
await shotElement(".story-stage", "screenshot-04-product-story.png");
await shotElement(".story-steps", "screenshot-05-steps.png");

await browser.close();
