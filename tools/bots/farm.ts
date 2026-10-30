// Starts headless Chromium with a fake 1080p30 camera and runs bots (bots/page.ts) in its tabs.
import { once } from "node:events";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { fileURLToPath } from "node:url";
import { build } from "esbuild";
import { chromium, type Browser, type Page } from "playwright";
import type { BotConfig, BotState } from "./page.ts";

export type { BotState };

// Node runs these files as they are (type stripping), so no TypeScript-only syntax such as parameter properties.
export class Bot {
  readonly name: string;
  private readonly page: Page;

  constructor(name: string, page: Page) {
    this.name = name;
    this.page = page;
  }

  state(): Promise<BotState> {
    return this.page.evaluate(() => window.bot.state());
  }

  /** Polls the bot's state until `done` holds; throws with the last state after `timeoutMs`. */
  async waitFor(done: (s: BotState) => boolean, timeoutMs = 30_000): Promise<BotState> {
    const until = Date.now() + timeoutMs;
    let last = await this.state();
    while (!done(last)) {
      if (Date.now() > until) throw new Error(`${this.name}: timed out, state ${JSON.stringify(last)}`);
      await new Promise((resolve) => setTimeout(resolve, 250));
      last = await this.state();
    }
    return last;
  }

  cameraSet(param: string, value: number): Promise<string> {
    return this.page.evaluate(([p, v]) => window.bot.cameraSet(p, v), [param, value] as const);
  }

  /** camera.set with any control (auto, manual value, white balance preset); returns its id. */
  cameraSetControl(param: string, control: Record<string, unknown>): Promise<string> {
    return this.page.evaluate(([p, c]) => window.bot.cameraSetControl(p, c), [param, control] as const);
  }

  close(): Promise<void> {
    return this.page.close();
  }
}

export class BotFarm {
  private readonly browser: Browser;
  private readonly server: Server;
  private readonly url: string;

  private constructor(browser: Browser, server: Server, url: string) {
    this.browser = browser;
    this.server = server;
    this.url = url;
  }

  static async start(): Promise<BotFarm> {
    const bundle = await build({
      entryPoints: [fileURLToPath(new URL("./page.ts", import.meta.url))],
      bundle: true,
      format: "esm",
      platform: "browser",
      target: "chrome120",
      write: false,
    });
    const script = bundle.outputFiles[0]?.text ?? "";
    // A localhost page is a secure context, which getUserMedia and WebRTC need.
    const server = createServer((req, res) => {
      if (req.url === "/page.js") res.writeHead(200, { "content-type": "text/javascript" }).end(script);
      else res.writeHead(200, { "content-type": "text/html" }).end('<!doctype html><script type="module" src="/page.js"></script>');
    });
    server.listen(0, "127.0.0.1");
    await once(server, "listening");
    const browser = await chromium.launch({
      ...(process.env.BOT_BROWSER_CHANNEL ? { channel: process.env.BOT_BROWSER_CHANNEL } : {}),
      ...(process.env.BOT_CHROMIUM_PATH ? { executablePath: process.env.BOT_CHROMIUM_PATH } : {}),
      args: [
        // Chromium's own test camera: a moving pattern with a frame counter, at the size and rate asked for.
        "--use-fake-device-for-media-stream=fps=30",
        "--use-fake-ui-for-media-stream",
        "--autoplay-policy=no-user-gesture-required",
      ],
    });
    return new BotFarm(browser, server, `http://localhost:${String((server.address() as AddressInfo).port)}/`);
  }

  async launch(name: string, config: BotConfig): Promise<Bot> {
    const page = await this.browser.newPage();
    page.on("pageerror", (error) => {
      console.error(`${name}: ${error.message}`);
    });
    await page.goto(this.url);
    await page.waitForFunction(() => "bot" in window);
    await page.evaluate((cfg) => window.bot.start(cfg), config);
    return new Bot(name, page);
  }

  /**
   * A plain tab of the same browser (fake camera, autoplay), for a real page such as media-server's /viewer/. It
   * says it is desktop Chrome: off a secure context there is no navigator.userAgentData, and mediasoup-client then
   * reads the user agent, where headless Chromium's "HeadlessChrome/…" is not recognized.
   */
  page(): Promise<Page> {
    const chrome = `Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/${this.browser.version()} Safari/537.36`;
    return this.browser.newPage({ locale: "en-US", userAgent: chrome });
  }

  async close(): Promise<void> {
    await this.browser.close();
    this.server.close();
  }
}
