import { createReadStream } from "node:fs";
import type { IncomingMessage, ServerResponse } from "node:http";
import { join } from "node:path";
import type { Logger } from "pino";
import { TokenError, type TokenVerifier } from "../auth/jwt.js";
import type { AccessTokenClaims, ErrorResponse, RoomLicenseStatus } from "../contracts/types.js";
import type { DvrManager } from "./manager.js";

const PLAYLIST = /^\/dvr\/([0-9a-f-]{36})\/index\.m3u8$/;
const FILE = /^\/dvr\/([0-9a-f-]{36})\/r(\d{1,9})\/(init\.mp4|\d{1,9}\.m4s)$/;

export interface DvrHttpDeps {
  dvr: DvrManager;
  verifier: TokenVerifier;
  /** The table's license as media-server knows it now (its room's, else the backend's). */
  licenseOf: (tableId: string, claims: AccessTokenClaims) => Promise<RoomLicenseStatus>;
  log: Logger;
}

function fail(res: ServerResponse, status: number, code: string, message: string): void {
  const body: ErrorResponse = { detail: { code, message } };
  res.writeHead(status, { "content-type": "application/json" }).end(JSON.stringify(body));
}

/**
 * GET /dvr/{table_id}/index.m3u8 and the segments it lists (SPEC 7.2 step 4), for a viewer's access
 * token for that table in `Authorization: Bearer`. Returns false for any other path.
 */
export function handleDvr(deps: DvrHttpDeps, req: IncomingMessage, res: ServerResponse): boolean {
  const path = new URL(req.url ?? "/", "http://localhost").pathname;
  const playlist = PLAYLIST.exec(path);
  const file = playlist ? null : FILE.exec(path);
  const tableId = playlist?.[1] ?? file?.[1];
  if (tableId === undefined) return false;
  if (req.method !== "GET") {
    fail(res, 405, "method_not_allowed", "GET only");
    return true;
  }
  void serve(deps, req, res, tableId, file ? { run: Number(file[2]), name: file[3] as string } : undefined).catch((error: unknown) => {
    deps.log.error({ err: error, table_id: tableId }, "DVR request failed");
    if (!res.headersSent) fail(res, 500, "internal", "internal error");
    else res.destroy();
  });
  return true;
}

async function serve(
  deps: DvrHttpDeps,
  req: IncomingMessage,
  res: ServerResponse,
  tableId: string,
  file: { run: number; name: string } | undefined,
): Promise<void> {
  const header = req.headers.authorization ?? "";
  const token = header.startsWith("Bearer ") ? header.slice("Bearer ".length).trim() : "";
  if (!token) {
    fail(res, 401, "unauthorized", "Authorization: Bearer <access token> required");
    return;
  }
  let claims: AccessTokenClaims;
  try {
    claims = await deps.verifier.verify(token);
  } catch (error) {
    if (!(error instanceof TokenError)) throw error;
    fail(res, 401, "unauthorized", error.message);
    return;
  }
  if (claims.role !== "viewer" || claims.table_id !== tableId) {
    fail(res, 403, "forbidden", "the token is not a viewer's token for this table");
    return;
  }
  if ((await deps.licenseOf(tableId, claims)) === "blocked") {
    fail(res, 403, "license_blocked", "the license blocks this table");
    return;
  }
  const table = deps.dvr.table(tableId);
  if (!file) {
    if (!table || table.index.size === 0) {
      fail(res, 404, "not_found", "no DVR buffer for this table yet");
      return;
    }
    res.writeHead(200, { "content-type": "application/vnd.apple.mpegurl", "cache-control": "no-cache" }).end(table.index.render());
    return;
  }
  // Only what the playlist lists now: a segment pushed out of the window is gone (404).
  const listed = file.name === "init.mp4" ? table?.index.liveRuns().has(file.run) : table?.index.has(file.run, file.name);
  if (!table || !listed) {
    fail(res, 404, "not_found", "not in the DVR window");
    return;
  }
  const stream = createReadStream(join(table.dir, `r${String(file.run)}`, file.name));
  stream.once("open", () => {
    res.writeHead(200, {
      "content-type": file.name === "init.mp4" ? "video/mp4" : "video/iso.segment",
      "cache-control": "private, max-age=600",
    });
    stream.pipe(res);
  });
  stream.once("error", () => {
    // Deleted between the check and the read.
    if (!res.headersSent) fail(res, 404, "not_found", "not in the DVR window");
    else res.destroy();
  });
}
