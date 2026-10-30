import { once } from "node:events";
import { mkdtempSync, writeFileSync } from "node:fs";
import type { AddressInfo } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll, beforeAll, expect, test } from "vitest";
import { createHttpServer } from "../src/http.js";
import { createLogger } from "../src/log.js";
import { webRoute } from "../src/web.js";

const log = createLogger("silent");
const built = mkdtempSync(join(tmpdir(), "viewer-"));
writeFileSync(join(built, "viewer.html"), "<!doctype html><title>PokerCam</title>");
writeFileSync(join(built, "viewer.js"), "console.log('viewer');");
const server = createHttpServer(log, undefined, [webRoute(built, log)]);
const notBuilt = createHttpServer(log, undefined, [webRoute(join(built, "missing"), log)]);
const base: string[] = [];

beforeAll(async () => {
  for (const s of [server, notBuilt]) {
    s.listen(0, "127.0.0.1");
    await once(s, "listening");
    base.push(`http://127.0.0.1:${String((s.address() as AddressInfo).port)}`);
  }
});

afterAll(() => {
  server.close();
  notBuilt.close();
});

test("the viewer page and its script are served, /viewer goes to /viewer/", async () => {
  const [url] = base;
  const page = await fetch(`${String(url)}/viewer/`);
  expect(page.status).toBe(200);
  expect(page.headers.get("content-type")).toBe("text/html; charset=utf-8");
  expect(await page.text()).toContain("PokerCam");
  const script = await fetch(`${String(url)}/viewer/viewer.js?v=1`);
  expect(script.headers.get("content-type")).toBe("text/javascript; charset=utf-8");
  expect(await script.text()).toContain("viewer");
  const bare = await fetch(`${String(url)}/viewer`, { redirect: "manual" });
  expect([bare.status, bare.headers.get("location")]).toEqual([301, "/viewer/"]);
});

test("nothing else is served from the build directory", async () => {
  const [url] = base;
  for (const path of ["/viewer/../package.json", "/viewer/viewer.html", "/viewer/other.js"]) {
    expect((await fetch(`${String(url)}${path}`)).status, path).toBe(404);
  }
  expect((await fetch(`${String(url)}/viewer/`, { method: "POST" })).status).toBe(404);
});

test("without a build the page answers 404, the server keeps running", async () => {
  const [, url] = base;
  const res = await fetch(`${String(url)}/viewer/`);
  expect(res.status).toBe(404);
  expect(await res.json()).toEqual({ detail: { code: "not_found", message: "The viewer is not built" } });
  expect((await fetch(`${String(url)}/health`)).status).toBe(200);
});
