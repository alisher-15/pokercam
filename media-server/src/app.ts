import type { Server } from "node:http";
import type { Logger } from "pino";
import { TokenVerifier } from "./auth/jwt.js";
import { BackendClient } from "./backend.js";
import type { Config } from "./config.js";
import type { AccessTokenClaims, RoomLicenseStatus } from "./contracts/types.js";
import { handleDvr } from "./dvr/http.js";
import { DvrManager } from "./dvr/manager.js";
import { createHttpServer } from "./http.js";
import { RoomRegistry } from "./rooms/registry.js";
import { roomLicenseStatus } from "./rooms/room.js";
import { WorkerPool } from "./rooms/workers.js";
import { SignalingServer } from "./signaling/server.js";

/** How long a license answer fetched for a DVR request (a table without a room) is reused. */
const LICENSE_CACHE_MS = 60_000;

export interface App {
  server: Server;
  backend: BackendClient;
  verifier: TokenVerifier;
  rooms: RoomRegistry;
  dvr: DvrManager | undefined;
  /** Closes rooms, workers, FFmpeg runs and connections; the server stops listening. */
  close: () => Promise<void>;
}

/** media-server's parts wired together; index.ts and the tests share it. */
export async function createApp(config: Config, log: Logger, keyRefetchMs?: number): Promise<App> {
  const backend = new BackendClient(config.backendUrl, config.internalApiToken, log);
  const verifier = new TokenVerifier(backend, log, keyRefetchMs);
  const pool = await WorkerPool.start(config, log);
  const dvr = config.dvrEnabled ? await DvrManager.start(config, log) : undefined;
  const rooms = new RoomRegistry(pool, backend, config, log, dvr);

  // A DVR request for a table whose room is closed (camera gone, nobody watching) asks the backend.
  const fetched = new Map<string, { status: RoomLicenseStatus; at: number }>();
  const licenseOf = async (tableId: string, claims: AccessTokenClaims): Promise<RoomLicenseStatus> => {
    const room = rooms.find(tableId);
    if (room) return room.license.status;
    const cached = fetched.get(tableId);
    if (cached && Date.now() - cached.at < LICENSE_CACHE_MS) return cached.status;
    try {
      const status = roomLicenseStatus((await backend.tableLicense(tableId)).status);
      fetched.set(tableId, { status, at: Date.now() });
      return status;
    } catch (error) {
      log.warn({ err: error, table_id: tableId }, "license check for DVR failed, keeping the last answer");
      return cached?.status ?? roomLicenseStatus(claims.lic);
    }
  };

  const server = createHttpServer(
    log,
    {
      token: config.internalApiToken,
      recheckLicense: async (tableId) => {
        fetched.delete(tableId);
        const room = rooms.find(tableId);
        if (!room) return false;
        await room.checkLicense();
        return true;
      },
    },
    dvr ? [(req, res) => handleDvr({ dvr, verifier, licenseOf, log }, req, res)] : [],
  );
  const signaling = new SignalingServer({ verifier, rooms, log });
  signaling.attach(server);

  return {
    server,
    backend,
    verifier,
    rooms,
    dvr,
    close: async () => {
      signaling.close();
      rooms.closeAll();
      await dvr?.close();
      pool.close();
      server.closeAllConnections();
      server.close();
    },
  };
}
