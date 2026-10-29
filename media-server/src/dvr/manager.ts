import { mkdir, readdir, rm } from "node:fs/promises";
import { join } from "node:path";
import type { types } from "mediasoup";
import type { Logger } from "pino";
import type { DvrInfoMessage } from "../contracts/types.js";
import { message } from "../contracts/validate.js";
import { withContext } from "../log.js";
import { PortPool } from "./ports.js";
import { TableDvr } from "./recorder.js";

export interface DvrConfig {
  /** tmpfs mount (SPEC 7.2): /dvr/{table_id}/. */
  dvrDir: string;
  /** Segments kept per table: 600 × 1 s = 10 minutes. */
  dvrSegments: number;
  dvrRtpPortMin: number;
  dvrRtpPortMax: number;
  ffmpegPath: string;
}

export const playlistUrl = (tableId: string): string => `/dvr/${tableId}/index.m3u8`;

/** Every table's DVR on this server. A restart starts every buffer over (SPEC 11.1). */
export class DvrManager {
  private readonly tables = new Map<string, TableDvr>();
  private readonly ports: PortPool;

  private constructor(
    private readonly config: DvrConfig,
    private readonly log: Logger,
  ) {
    this.ports = new PortPool(config.dvrRtpPortMin, config.dvrRtpPortMax);
  }

  /** Empties the DVR directory: whatever a previous process left there is not in any playlist. */
  static async start(config: DvrConfig, log: Logger): Promise<DvrManager> {
    await mkdir(config.dvrDir, { recursive: true });
    for (const entry of await readdir(config.dvrDir)) await rm(join(config.dvrDir, entry), { recursive: true, force: true });
    log.info({ dir: config.dvrDir, segments: config.dvrSegments }, "DVR ready");
    return new DvrManager(config, log);
  }

  table(tableId: string): TableDvr | undefined {
    return this.tables.get(tableId);
  }

  /** A camera started publishing on this table: record it (SPEC 7.2 step 1). */
  record(tableId: string, router: types.Router, producer: types.Producer): Promise<void> {
    let table = this.tables.get(tableId);
    if (!table) {
      const log = withContext(this.log, { table_id: tableId });
      table = new TableDvr(tableId, join(this.config.dvrDir, tableId), this.config.dvrSegments, { ffmpegPath: this.config.ffmpegPath, ports: this.ports, log }, log);
      this.tables.set(tableId, table);
    }
    return table.record(router, producer);
  }

  /** The buffer viewers can rewind in, or undefined while the table has none. */
  info(tableId: string): DvrInfoMessage | undefined {
    const range = this.tables.get(tableId)?.index.range();
    if (!range) return undefined;
    return message("dvr.info", tableId, { available_from: range.from, available_to: range.to, playlist_url: playlistUrl(tableId) });
  }

  async close(): Promise<void> {
    await Promise.all([...this.tables.values()].map((table) => table.stop()));
  }
}
