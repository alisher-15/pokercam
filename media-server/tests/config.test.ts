import { expect, test } from "vitest";
import { loadConfig } from "../src/config.js";

test("defaults", () => {
  expect(loadConfig({})).toEqual({ port: 3000, logLevel: "info" });
});

test("reads PORT and LOG_LEVEL", () => {
  expect(loadConfig({ PORT: "4000", LOG_LEVEL: "DEBUG" })).toEqual({ port: 4000, logLevel: "debug" });
});

test("rejects a bad PORT", () => {
  expect(() => loadConfig({ PORT: "http" })).toThrow(/PORT/);
});
