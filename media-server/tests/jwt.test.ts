import { generateKeyPairSync, randomUUID } from "node:crypto";
import { describe, expect, test } from "vitest";
import { TokenError, TokenVerifier } from "../src/auth/jwt.js";
import type { BackendClient } from "../src/backend.js";
import { createLogger } from "../src/log.js";
import { token } from "./support.js";

function verifierWith(pems: string[]) {
  let calls = 0;
  const backend = {
    jwtKey: () => Promise.resolve({ algorithm: "EdDSA" as const, public_key_pem: pems[Math.min(calls++, pems.length - 1)] as string }),
  } as unknown as BackendClient;
  return { verifier: new TokenVerifier(backend, createLogger("silent"), 0), calls: () => calls };
}

// The key support.token() signs with is the one FakeBackend publishes; reach it through a FakeBackend-like call.
async function realPem(): Promise<string> {
  const { FakeBackend, INTERNAL_TOKEN } = await import("./support.js");
  const backend = new FakeBackend();
  const url = await backend.start();
  const res = await fetch(`${url}/api/v1/internal/jwt-key`, { headers: { "X-Internal-Token": INTERNAL_TOKEN } });
  backend.server.close();
  return ((await res.json()) as { public_key_pem: string }).public_key_pem;
}

describe("TokenVerifier", () => {
  test("accepts a token signed by the backend's key", async () => {
    const { verifier } = verifierWith([await realPem()]);
    const table = randomUUID();
    const claims = await verifier.verify(token({ role: "viewer", sub: randomUUID(), table_id: table }));
    expect(claims.table_id).toBe(table);
  });

  test("rejects a token signed by another key", async () => {
    const { verifier } = verifierWith([await realPem()]);
    const other = generateKeyPairSync("ed25519").privateKey;
    await expect(verifier.verify(token({ role: "viewer", sub: randomUUID() }, other))).rejects.toThrow(TokenError);
  });

  test("rejects an expired token", async () => {
    const { verifier } = verifierWith([await realPem()]);
    const jwt = token({ role: "viewer", sub: randomUUID(), exp: Math.floor(Date.now() / 1000) - 1 });
    await expect(verifier.verify(jwt)).rejects.toThrow("expired");
  });

  test("rejects claims outside the contract", async () => {
    const { verifier } = verifierWith([await realPem()]);
    const jwt = token({ role: "admin" as "viewer", sub: randomUUID() });
    await expect(verifier.verify(jwt)).rejects.toThrow("bad claims");
  });

  test("rejects garbage", async () => {
    const { verifier } = verifierWith([await realPem()]);
    await expect(verifier.verify("not.a.jwt")).rejects.toThrow(TokenError);
    await expect(verifier.verify("abc")).rejects.toThrow(TokenError);
  });

  test("fetches the key again when the backend's key changed", async () => {
    const stale = generateKeyPairSync("ed25519").publicKey.export({ type: "spki", format: "pem" }).toString();
    const { verifier, calls } = verifierWith([stale, await realPem()]);
    await verifier.loadKey();
    await expect(verifier.verify(token({ role: "viewer", sub: randomUUID() }))).resolves.toMatchObject({ role: "viewer" });
    expect(calls()).toBe(2);
  });
});
