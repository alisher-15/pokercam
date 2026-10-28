import { expect, test } from "vitest";
import { createLogger, withContext } from "../src/log.js";

function capture() {
  const lines: Record<string, unknown>[] = [];
  const destination = { write: (line: string) => lines.push(JSON.parse(line) as Record<string, unknown>) };
  return { lines, log: createLogger("info", destination) };
}

test("every line has the context fields, null when unknown", () => {
  const { lines, log } = capture();
  log.info("started");
  expect(lines[0]).toMatchObject({ level: "info", message: "started", table_id: null, device_id: null, session_id: null });
  expect(typeof lines[0]?.ts).toBe("string");
});

test("a context logger fills them in", () => {
  const { lines, log } = capture();
  withContext(log, { table_id: "t1", session_id: "s1" }).info({ bitrate_kbps: 3950 }, "stats");
  expect(lines[0]).toMatchObject({ table_id: "t1", device_id: null, session_id: "s1", bitrate_kbps: 3950 });
  // Each field appears once, so every JSON parser reads the same value.
  expect(JSON.stringify(lines[0]).match(/"table_id"/g)).toHaveLength(1);
});
