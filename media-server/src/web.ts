import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import type { Logger } from "pino";
import type { Route } from "./http.js";

/** Where `npm run build:web` puts the browser viewer: dist/web, next to the compiled server. */
export const WEB_DIR = fileURLToPath(new URL("../dist/web/", import.meta.url));

const FILES: Record<string, { file: string; type: string } | undefined> = {
  "/viewer/": { file: "viewer.html", type: "text/html; charset=utf-8" },
  "/viewer/viewer.js": { file: "viewer.js", type: "text/javascript; charset=utf-8" },
};

/**
 * The browser viewer, the club's PC until the Windows client (stage 6): static files only. The page signs in
 * with the client's activation key at the backend and joins the table here like any viewer.
 */
export function webRoute(dir: string, log: Logger): Route {
  return (req, res) => {
    if (req.method !== "GET") return false;
    const path = (req.url ?? "").split("?")[0] ?? "";
    if (path === "/viewer") {
      res.writeHead(301, { location: "/viewer/" }).end();
      return true;
    }
    const entry = FILES[path];
    if (!entry) return false;
    readFile(join(dir, entry.file)).then(
      (body) => {
        res.writeHead(200, { "content-type": entry.type, "cache-control": "no-cache" }).end(body);
      },
      (error: unknown) => {
        log.warn({ err: error }, "the viewer is not built (npm run build:web)");
        res
          .writeHead(404, { "content-type": "application/json" })
          .end(JSON.stringify({ detail: { code: "not_found", message: "The viewer is not built" } }));
      },
    );
    return true;
  };
}
