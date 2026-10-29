import { once } from "node:events";
import { createApp } from "./app.js";
import { loadConfig } from "./config.js";
import { createLogger } from "./log.js";

const config = loadConfig();
const log = createLogger(config.logLevel);
const app = await createApp(config, log);

app.server.listen(config.port);
await once(app.server, "listening");
log.info({ port: config.port, max_viewers_per_table: config.maxViewersPerTable, dvr: config.dvrEnabled }, "media-server listening");

// The backend may start after us: neither blocks serving.
app.verifier.loadKey().catch((error: unknown) => {
  log.warn({ err: error }, "JWT key not loaded yet; it is fetched again at the first join");
});
void app.backend.announceStart();

for (const signal of ["SIGTERM", "SIGINT"] as const) {
  process.once(signal, () => {
    log.info({ signal }, "shutting down");
    void app.close().finally(() => process.exit(0));
  });
}
