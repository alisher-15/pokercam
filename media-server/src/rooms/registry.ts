import type { Logger } from "pino";
import type { BackendClient } from "../backend.js";
import type { Config } from "../config.js";
import { Room, type RoomLicense } from "./room.js";
import type { WorkerPool } from "./workers.js";

/** Rooms by table id, created on the first join and closed when the last peer leaves. */
export class RoomRegistry {
  private readonly rooms = new Map<string, Room>();
  private readonly creating = new Map<string, Promise<Room>>();

  constructor(
    private readonly pool: WorkerPool,
    private readonly backend: BackendClient,
    private readonly config: Pick<Config, "maxViewersPerTable" | "licenseCheckIntervalMs">,
    private readonly log: Logger,
  ) {}

  find(tableId: string): Room | undefined {
    return this.rooms.get(tableId);
  }

  get size(): number {
    return this.rooms.size;
  }

  /**
   * The table's room; a new one starts with the license from the joiner's token and checks the backend
   * right away (SPEC 7.1: "при старте комнаты").
   */
  async get(tableId: string, fromToken: RoomLicense): Promise<Room> {
    const existing = this.rooms.get(tableId);
    if (existing) return existing;
    let pending = this.creating.get(tableId);
    if (!pending) {
      pending = this.create(tableId, fromToken).finally(() => this.creating.delete(tableId));
      this.creating.set(tableId, pending);
    }
    return pending;
  }

  private async create(tableId: string, fromToken: RoomLicense): Promise<Room> {
    const { router, webRtcServer } = await this.pool.createRouter();
    const room = new Room(tableId, router, webRtcServer, fromToken, {
      backend: this.backend,
      log: this.log,
      maxViewers: this.config.maxViewersPerTable,
      licenseCheckIntervalMs: this.config.licenseCheckIntervalMs,
      onEmpty: (empty) => {
        this.close(empty);
      },
    });
    this.rooms.set(tableId, room);
    await room.checkLicense();
    room.log.info("room opened");
    return room;
  }

  private close(room: Room): void {
    if (this.rooms.get(room.tableId) !== room) return;
    this.rooms.delete(room.tableId);
    room.close();
    room.log.info("room closed");
  }

  closeAll(): void {
    for (const room of [...this.rooms.values()]) this.close(room);
  }
}
