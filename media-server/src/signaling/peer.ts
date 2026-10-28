import { randomUUID } from "node:crypto";
import type { types } from "mediasoup";
import type { Logger } from "pino";
import { WebSocket } from "ws";
import type { Message } from "../contracts/messages.js";
import type { AccessTokenClaims } from "../contracts/types.js";
import type { Room } from "../rooms/room.js";

/** One WebSocket connection: a camera or a viewer in one table's room. */
export class Peer {
  readonly id = randomUUID();
  readonly sessionId = randomUUID();
  claims: AccessTokenClaims | undefined;
  room: Room | undefined;
  readonly transports = new Map<string, types.WebRtcTransport>();
  readonly consumers = new Map<string, types.Consumer>();
  /** Messages of one peer are handled one at a time, in order. */
  queue: Promise<void> = Promise.resolve();

  constructor(
    private readonly ws: WebSocket,
    public log: Logger,
  ) {}

  get role(): AccessTokenClaims["role"] | undefined {
    return this.claims?.role;
  }

  send(msg: Message): void {
    if (this.ws.readyState === WebSocket.OPEN) this.ws.send(JSON.stringify(msg));
  }

  close(code: number, reason: string): void {
    this.ws.close(code, reason);
  }

  /** Closing the transports closes their producers and consumers too. */
  closeMedia(): void {
    for (const transport of this.transports.values()) transport.close();
    this.transports.clear();
    this.consumers.clear();
  }
}
