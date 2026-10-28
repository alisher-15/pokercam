import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, test } from "vitest";
import type { Message } from "../src/contracts/messages.js";
import { parseMessage, validateMessage } from "../src/contracts/validate.js";

const EXAMPLES = join(import.meta.dirname, "../../contracts/examples/ws");
const examples = ["control", "signaling"].flatMap((group) =>
  readdirSync(join(EXAMPLES, group)).map((file) => `${group}/${file}`),
);
const read = (rel: string): unknown => JSON.parse(readFileSync(join(EXAMPLES, rel), "utf8"));

describe("every example message is accepted", () => {
  test.each(examples)("%s", (rel) => {
    const result = validateMessage(read(rel));
    expect(result).toMatchObject({ ok: true });
  });
});

test("messages narrow by type", () => {
  const result = parseMessage(JSON.stringify(read("control/camera.set.json")));
  if (!result.ok) throw new Error(result.error);
  const describe = (m: Message): string => (m.type === "camera.set" ? m.payload.param : m.type);
  expect(describe(result.message)).toBe("iso");
});

describe("bad messages are rejected", () => {
  const set = read("control/camera.set.json") as Record<string, unknown>;
  test.each([
    ["not JSON", "{", /not JSON/],
    ["no envelope", JSON.stringify({ hello: 1 }), /envelope/],
    ["unknown type", JSON.stringify({ ...set, type: "camera.reboot" }), /unknown message type camera.reboot/],
    ["bad payload", JSON.stringify({ ...set, payload: { param: "flash", control: { mode: "auto" } } }), /camera.set/],
    ["manual without value", JSON.stringify({ ...set, payload: { param: "iso", control: { mode: "manual" } } }), /camera.set/],
  ])("%s", (_name, raw, error) => {
    const result = parseMessage(raw);
    expect(result.ok).toBe(false);
    if (!result.ok) expect(result.error).toMatch(error);
  });
});
