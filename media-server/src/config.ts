import { cpus } from "node:os";

// Development default shared with the backend (app/config.py); production refuses it.
const DEV_INTERNAL_API_TOKEN = "dev-only-internal-api-token";

export interface Config {
  port: number;
  logLevel: string;
  /** Where media-server reaches the backend's internal API. */
  backendUrl: string;
  internalApiToken: string;
  /** IP the RTC sockets bind to inside the container or host. */
  rtcListenIp: string;
  /** Address clients reach those sockets at: the server's public or LAN address. */
  rtcAnnouncedAddress: string;
  /** One port per mediasoup worker, UDP and TCP, starting here. */
  rtcPortMin: number;
  workers: number;
  /** SPEC 7.1: 5; the pilot runs 1 (SPEC 2). */
  maxViewersPerTable: number;
  /** SPEC 7.1: the license is rechecked every 10 minutes. */
  licenseCheckIntervalMs: number;
}

function int(env: NodeJS.ProcessEnv, name: string, fallback: number, min = 1, max = 65535): number {
  const raw = env[name];
  const value = raw === undefined || raw === "" ? fallback : Number(raw);
  if (!Number.isInteger(value) || value < min || value > max) throw new Error(`${name} must be an integer ${String(min)}..${String(max)}, got ${raw ?? ""}`);
  return value;
}

/** Settings from the environment (see .env.example in the repository root). */
export function loadConfig(env: NodeJS.ProcessEnv = process.env): Config {
  const production = env.ENVIRONMENT === "production";
  const internalApiToken = env.INTERNAL_API_TOKEN || DEV_INTERNAL_API_TOKEN;
  if (production && internalApiToken === DEV_INTERNAL_API_TOKEN) throw new Error("production needs INTERNAL_API_TOKEN");
  const rtcPortMin = int(env, "RTC_PORT_MIN", 40000);
  const rtcPortMax = int(env, "RTC_PORT_MAX", rtcPortMin + 3);
  if (rtcPortMax < rtcPortMin) throw new Error("RTC_PORT_MAX must not be below RTC_PORT_MIN");
  // SPEC 7.1: a worker per core, but each needs its own published port.
  const workers = Math.min(int(env, "MEDIASOUP_WORKERS", cpus().length, 1, 256), rtcPortMax - rtcPortMin + 1);
  return {
    port: int(env, "PORT", 3000),
    logLevel: env.LOG_LEVEL?.toLowerCase() ?? "info",
    backendUrl: (env.BACKEND_URL || "http://localhost:8000").replace(/\/$/, ""),
    internalApiToken,
    rtcListenIp: env.RTC_LISTEN_IP || "0.0.0.0",
    rtcAnnouncedAddress: env.RTC_ANNOUNCED_ADDRESS || "127.0.0.1",
    rtcPortMin,
    workers,
    maxViewersPerTable: int(env, "MAX_VIEWERS_PER_TABLE", 5, 1, 1000),
    licenseCheckIntervalMs: int(env, "LICENSE_CHECK_INTERVAL_S", 600, 1, 86400) * 1000,
  };
}
