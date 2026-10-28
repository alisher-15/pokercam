import { expect, test } from "vitest";
import { createLogger, withContext } from "../src/log.js";

function capture() {
  const raw: string[] = [];
  const lines: Record<string, unknown>[] = [];
  const destination = {
    write: (line: string) => {
      raw.push(line);
      lines.push(JSON.parse(line) as Record<string, unknown>);
    },
  };
  return { raw, lines, log: createLogger("info", destination) };
}

test("every line has the context fields, null when unknown", () => {
  const { lines, log } = capture();
  log.info("started");
  expect(lines[0]).toMatchObject({ level: "info", message: "started", table_id: null, device_id: null, session_id: null });
  expect(typeof lines[0]?.ts).toBe("string");
});

test("a context logger fills them in", () => {
  const { raw, lines, log } = capture();
  withContext(log, { table_id: "t1", session_id: "s1" }).info({ bitrate_kbps: 3950 }, "stats");
  expect(lines[0]).toMatchObject({ table_id: "t1", device_id: null, session_id: "s1", bitrate_kbps: 3950 });
  // Each field appears once in the line itself, so every JSON parser reads the same value.
  expect(raw[0]?.match(/"table_id"/g)).toHaveLength(1);
});

test("a context replaces the one it is made from instead of adding to it", () => {
  const { raw, lines, log } = capture();
  const room = withContext(log, { table_id: "t1" });
  withContext(room, { table_id: "t1", device_id: "d1" }).child({ role: "camera" }).info("joined");
  expect(lines[0]).toMatchObject({ table_id: "t1", device_id: "d1", session_id: null, role: "camera" });
  for (const key of ["table_id", "device_id", "session_id", "service"]) {
    expect(raw[0]?.match(new RegExp(`"${key}"`, "g"))).toHaveLength(1);
  }
});
