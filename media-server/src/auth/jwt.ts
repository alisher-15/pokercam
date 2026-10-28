import { createPublicKey, verify, type KeyObject } from "node:crypto";
import type { Logger } from "pino";
import type { BackendClient } from "../backend.js";
import type { AccessTokenClaims } from "../contracts/types.js";
import { validateModel } from "../contracts/validate.js";

export class TokenError extends Error {}

/**
 * Checks access JWTs locally with the backend's Ed25519 public key (ADR-7): no backend call per token.
 * The key is fetched at start and fetched again when a signature fails (the backend's key changed).
 */
export class TokenVerifier {
  private key: KeyObject | undefined;
  private lastFetch = 0;

  constructor(
    private readonly backend: BackendClient,
    private readonly log: Logger,
    private readonly refetchAfterMs = 30_000,
  ) {}

  async loadKey(): Promise<void> {
    const { public_key_pem } = await this.backend.jwtKey();
    this.key = createPublicKey(public_key_pem);
    this.lastFetch = Date.now();
    this.log.info("JWT public key loaded");
  }

  async verify(token: string, now = Date.now()): Promise<AccessTokenClaims> {
    if (this.key === undefined || !this.signatureOk(token, this.key)) {
      if (Date.now() - this.lastFetch >= this.refetchAfterMs || this.key === undefined) {
        await this.loadKey().catch((error: unknown) => {
          this.log.warn({ err: error }, "could not fetch the JWT public key");
        });
      }
      if (this.key === undefined) throw new TokenError("the server cannot check tokens yet");
      if (!this.signatureOk(token, this.key)) throw new TokenError("bad signature");
    }
    const [header, payload] = token.split(".") as [string, string];
    if (decode(header).alg !== "EdDSA") throw new TokenError("unexpected algorithm");
    const claims = decode(payload);
    const checked = validateModel("auth/access_token_claims.json", claims);
    if (!checked.ok) throw new TokenError(`bad claims: ${checked.error}`);
    if ((claims.exp as number) * 1000 <= now) throw new TokenError("token expired");
    return claims as unknown as AccessTokenClaims;
  }

  private signatureOk(token: string, key: KeyObject): boolean {
    const parts = token.split(".");
    if (parts.length !== 3) throw new TokenError("not a JWT");
    const [header, payload, signature] = parts as [string, string, string];
    return verify(null, Buffer.from(`${header}.${payload}`), key, Buffer.from(signature, "base64url"));
  }
}

function decode(part: string): Record<string, unknown> {
  try {
    const value: unknown = JSON.parse(Buffer.from(part, "base64url").toString("utf8"));
    if (typeof value === "object" && value !== null) return value as Record<string, unknown>;
  } catch {
    // falls through
  }
  throw new TokenError("malformed token");
}
