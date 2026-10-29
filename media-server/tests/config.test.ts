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
    dvrEnabled: true,
    dvrDir: "/dvr",
    dvrSegments: 600,
    dvrRtpPortMin: 30000,
    dvrRtpPortMax: 30999,
    ffmpegPath: "ffmpeg",
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
    DVR_ENABLED: "false",
    DVR_DIR: "/tmp/dvr",
    DVR_SEGMENTS: "60",
    DVR_RTP_PORT_MIN: "51000",
    DVR_RTP_PORT_MAX: "51009",
    FFMPEG_PATH: "/usr/local/bin/ffmpeg",
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
    dvrEnabled: false,
    dvrDir: "/tmp/dvr",
    dvrSegments: 60,
    dvrRtpPortMin: 51000,
    dvrRtpPortMax: 51009,
    ffmpegPath: "/usr/local/bin/ffmpeg",
  });
});

test("rejects bad numbers", () => {
  expect(() => loadConfig({ PORT: "http" })).toThrow(/PORT/);
  expect(() => loadConfig({ RTC_PORT_MIN: "40010", RTC_PORT_MAX: "40000" })).toThrow(/RTC_PORT_MAX/);
  expect(() => loadConfig({ MAX_VIEWERS_PER_TABLE: "0" })).toThrow(/MAX_VIEWERS_PER_TABLE/);
  expect(() => loadConfig({ DVR_RTP_PORT_MIN: "51000", DVR_RTP_PORT_MAX: "51003" })).toThrow(/DVR_RTP_PORT_MAX/);
  expect(() => loadConfig({ DVR_SEGMENTS: "5" })).toThrow(/DVR_SEGMENTS/);
});

test("production refuses the development internal token", () => {
  expect(() => loadConfig({ ENVIRONMENT: "production" })).toThrow(/INTERNAL_API_TOKEN/);
  expect(loadConfig({ ENVIRONMENT: "production", INTERNAL_API_TOKEN: "s3cret" }).internalApiToken).toBe("s3cret");
});
