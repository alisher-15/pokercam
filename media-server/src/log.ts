import { pino, type DestinationStream, type Logger } from "pino";

/** Fields every log line carries (null when unknown), so logs can be filtered by table, phone and session. */
export interface LogContext {
  table_id?: string | null;
  device_id?: string | null;
  session_id?: string | null;
}

/** The logger each context logger was made from: pino repeats a key bound twice, so contexts never nest. */
const roots = new WeakMap<Logger, Logger>();

/** JSON lines in the same shape as the backend's: ts, level, message, table_id, device_id, session_id. */
export function createLogger(level: string, destination?: DestinationStream): Logger {
  const root = pino(
    {
      level,
      base: { service: "media-server" },
      messageKey: "message",
      timestamp: () => `,"ts":"${new Date().toISOString()}"`,
      formatters: { level: (label) => ({ level: label }) },
    },
    destination,
  );
  return withContext(root, {});
}

/** A logger for one table / phone / session, made from `createLogger`'s or another context logger. */
export function withContext(logger: Logger, context: LogContext): Logger {
  const { table_id = null, device_id = null, session_id = null } = context;
  const root = roots.get(logger) ?? logger;
  const child = root.child({ table_id, device_id, session_id });
  roots.set(child, root);
  return child;
}
