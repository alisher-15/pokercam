import { timingSafeEqual } from "node:crypto";
import { createServer, type Server, type ServerResponse } from "node:http";
import type { Logger } from "pino";

export interface InternalApi {
  token: string;
  /** Rechecks a table's license now; false if the table has no room on this server. */
  recheckLicense: (tableId: string) => Promise<boolean>;
}

function sendJson(res: ServerResponse, status: number, body: unknown): void {
  res.writeHead(status, { "content-type": "application/json" }).end(JSON.stringify(body));
}

function tokenOk(given: string | string[] | undefined, expected: string): boolean {
  if (typeof given !== "string") return false;
  const a = Buffer.from(given);
  const b = Buffer.from(expected);
  return a.length === b.length && timingSafeEqual(a, b);
}

const LICENSE_CHECK = /^\/internal\/tables\/([0-9a-f-]{36})\/license-check$/;

/**
 * HTTP endpoints of media-server: the health check, and /internal/* for the backend
 * («Применить сейчас» in the admin panel). The WebSocket at /ws is attached by SignalingServer.
 */
export function createHttpServer(log: Logger, internal?: InternalApi): Server {
  return createServer((req, res) => {
    if (req.method === "GET" && req.url === "/health") {
      sendJson(res, 200, { status: "ok" });
      return;
    }
    const check = req.method === "POST" && internal ? LICENSE_CHECK.exec(req.url ?? "") : null;
    if (check && internal) {
      if (!tokenOk(req.headers["x-internal-token"], internal.token)) {
        sendJson(res, 401, { detail: { code: "unauthorized", message: "X-Internal-Token required" } });
        return;
      }
      internal
        .recheckLicense(check[1] as string)
        .then((found) => {
          if (found) res.writeHead(204).end();
          else sendJson(res, 404, { detail: { code: "not_found", message: "No room for this table" } });
        })
        .catch((error: unknown) => {
          log.error({ err: error }, "license recheck failed");
          sendJson(res, 500, { detail: { code: "internal", message: "Recheck failed" } });
        });
      return;
    }
    log.debug({ method: req.method, url: req.url }, "not found");
    sendJson(res, 404, { detail: { code: "not_found", message: "Not found" } });
  });
}
