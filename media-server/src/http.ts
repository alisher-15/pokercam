import { createServer, type Server, type ServerResponse } from "node:http";
import type { Logger } from "pino";

function sendJson(res: ServerResponse, status: number, body: unknown): void {
  res.writeHead(status, { "content-type": "application/json" }).end(JSON.stringify(body));
}

/** HTTP endpoints of media-server. Stage 0 has the health check only; WebSocket and DVR come in stages 3 and 4. */
export function createHttpServer(log: Logger): Server {
  return createServer((req, res) => {
    if (req.method === "GET" && req.url === "/health") {
      sendJson(res, 200, { status: "ok" });
      return;
    }
    log.debug({ method: req.method, url: req.url }, "not found");
    sendJson(res, 404, { detail: { code: "not_found", message: "Not found" } });
  });
}
