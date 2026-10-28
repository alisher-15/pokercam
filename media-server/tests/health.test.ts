import { once } from "node:events";
import type { AddressInfo } from "node:net";
import { afterAll, beforeAll, expect, test } from "vitest";
import { createHttpServer } from "../src/http.js";
import { createLogger } from "../src/log.js";

const server = createHttpServer(createLogger("silent"));
let base = "";

beforeAll(async () => {
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  base = `http://127.0.0.1:${String((server.address() as AddressInfo).port)}`;
});

afterAll(() => {
  server.close();
});

test("GET /health answers ok", async () => {
  const res = await fetch(`${base}/health`);
  expect(res.status).toBe(200);
  expect(await res.json()).toEqual({ status: "ok" });
});

test("unknown paths answer 404 in the API error shape", async () => {
  const res = await fetch(`${base}/nope`);
  expect(res.status).toBe(404);
  expect(await res.json()).toEqual({ detail: { code: "not_found", message: "Not found" } });
});
