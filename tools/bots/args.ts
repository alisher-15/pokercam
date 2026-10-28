import { parseArgs } from "node:util";

/** Command line of the tools: where the backend and media-server are, and the club's activation key. */
export function toolArgs(extra: Record<string, { type: "string"; default?: string }> = {}) {
  const { values } = parseArgs({
    options: {
      backend: { type: "string", default: process.env.BACKEND_PUBLIC_URL ?? "http://localhost:8000" },
      media: { type: "string", default: process.env.MEDIA_WS_URL ?? "ws://localhost:3000/ws" },
      key: { type: "string", default: process.env.CLUB_KEY ?? "" },
      table: { type: "string", default: "1" },
      ...extra,
    },
  });
  if (!values.key) throw new Error("--key <club activation key> is required (or CLUB_KEY)");
  return values as Record<string, string>;
}
