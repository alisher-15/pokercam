export interface Config {
  port: number;
  logLevel: string;
}

/** Settings from the environment (see .env.example in the repository root). */
export function loadConfig(env: NodeJS.ProcessEnv = process.env): Config {
  const port = Number(env.PORT ?? "3000");
  if (!Number.isInteger(port) || port <= 0 || port > 65535) throw new Error(`PORT must be a TCP port, got ${env.PORT ?? ""}`);
  return { port, logLevel: env.LOG_LEVEL?.toLowerCase() ?? "info" };
}
