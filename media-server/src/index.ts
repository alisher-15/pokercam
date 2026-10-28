import { once } from "node:events";
import { TokenVerifier } from "./auth/jwt.js";
import { BackendClient } from "./backend.js";
import { loadConfig } from "./config.js";
import { createHttpServer } from "./http.js";
import { createLogger } from "./log.js";
import { RoomRegistry } from "./rooms/registry.js";
import { WorkerPool } from "./rooms/workers.js";
import { SignalingServer } from "./signaling/server.js";

const config = loadConfig();
const log = createLogger(config.logLevel);
const backend = new BackendClient(config.backendUrl, config.internalApiToken, log);
const verifier = new TokenVerifier(backend, log);
const pool = await WorkerPool.start(config, log);
const rooms = new RoomRegistry(pool, backend, config, log);

const server = createHttpServer(log, {
  token: config.internalApiToken,
  recheckLicense: async (tableId) => {
    const room = rooms.find(tableId);
    if (!room) return false;
    await room.checkLicense();
    return true;
  },
});
const signaling = new SignalingServer({ verifier, rooms, log });
signaling.attach(server);

server.listen(config.port);
await once(server, "listening");
log.info({ port: config.port, max_viewers_per_table: config.maxViewersPerTable }, "media-server listening");

// The backend may start after us: neither blocks serving.
verifier.loadKey().catch((error: unknown) => {
  log.warn({ err: error }, "JWT key not loaded yet; it is fetched again at the first join");
});
void backend.announceStart();

for (const signal of ["SIGTERM", "SIGINT"] as const) {
  process.once(signal, () => {
    log.info({ signal }, "shutting down");
    signaling.close();
    rooms.closeAll();
    pool.close();
    server.close(() => process.exit(0));
    server.closeAllConnections();
  });
}
