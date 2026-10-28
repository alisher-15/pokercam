import { once } from "node:events";
import { loadConfig } from "./config.js";
import { createHttpServer } from "./http.js";
import { createLogger } from "./log.js";

const config = loadConfig();
const log = createLogger(config.logLevel);
const server = createHttpServer(log);

server.listen(config.port);
await once(server, "listening");
log.info({ port: config.port }, "media-server listening");

for (const signal of ["SIGTERM", "SIGINT"] as const) {
  process.once(signal, () => {
    log.info({ signal }, "shutting down");
    server.close(() => process.exit(0));
    server.closeAllConnections();
  });
}
