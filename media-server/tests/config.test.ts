import { cpus } from "node:os";
import { expect, test } from "vitest";
import { loadConfig } from "../src/config.js";

test("defaults", () => {
  expect(loadConfig({})).toEqual({
    port: 3000,
    logLevel: "info",
    backendUrl: "http://localhost:8000",
    internalApiToken: "dev-only-internal-api-token",
    rtcListenIp: "0.0.0.0",
    rtcAnnouncedAddress: "127.0.0.1",
    rtcPortMin: 40000,
    workers: Math.min(cpus().length, 4),
    maxViewersPerTable: 5,
    licenseCheckIntervalMs: 600_000,
  });
});

test("reads the environment", () => {
  const config = loadConfig({
    PORT: "4000",
    LOG_LEVEL: "DEBUG",
    BACKEND_URL: "http://backend:8000/",
    RTC_ANNOUNCED_ADDRESS: "192.168.1.10",
    RTC_PORT_MIN: "45000",
    RTC_PORT_MAX: "45001",
    MEDIASOUP_WORKERS: "8",
    MAX_VIEWERS_PER_TABLE: "1",
    LICENSE_CHECK_INTERVAL_S: "60",
  });
  expect(config).toMatchObject({
    port: 4000,
    logLevel: "debug",
    backendUrl: "http://backend:8000",
    rtcAnnouncedAddress: "192.168.1.10",
    rtcPortMin: 45000,
    workers: Math.min(8, cpus().length, 2), // no more workers than published ports
    maxViewersPerTable: 1,
    licenseCheckIntervalMs: 60_000,
  });
});

test("rejects bad numbers", () => {
  expect(() => loadConfig({ PORT: "http" })).toThrow(/PORT/);
  expect(() => loadConfig({ RTC_PORT_MIN: "40010", RTC_PORT_MAX: "40000" })).toThrow(/RTC_PORT_MAX/);
  expect(() => loadConfig({ MAX_VIEWERS_PER_TABLE: "0" })).toThrow(/MAX_VIEWERS_PER_TABLE/);
});

test("production refuses the development internal token", () => {
  expect(() => loadConfig({ ENVIRONMENT: "production" })).toThrow(/INTERNAL_API_TOKEN/);
  expect(loadConfig({ ENVIRONMENT: "production", INTERNAL_API_TOKEN: "s3cret" }).internalApiToken).toBe("s3cret");
});
