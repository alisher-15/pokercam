import type { Message } from "../contracts/messages.js";
import { message } from "../contracts/validate.js";
import type { Room } from "../rooms/room.js";
import type { Peer } from "../signaling/peer.js";

/** A control message the sender may not send; the signaling layer answers it with signaling.error. */
export class ForbiddenMessage extends Error {}

/**
 * Control channel of a table (SPEC 5.3, ADR-6): the camera's reports go to the viewers, a viewer's
 * camera.set goes to the camera, and the camera's camera.ack back to that viewer only.
 */
export function routeControl(room: Room, from: Peer, msg: Message): void {
  if (from.role === "camera") {
    switch (msg.type) {
      case "camera.capabilities":
        room.cache.capabilities = msg;
        room.broadcast(msg, true);
        return;
      case "camera.state":
        room.cache.state = msg;
        room.broadcast(msg, true);
        return;
      case "device.telemetry":
        room.cache.telemetry = msg;
        room.broadcast(msg, true);
        return;
      case "device.alert":
        room.broadcast(msg, true);
        return;
      case "camera.ack": {
        const viewerId = room.pendingAcks.get(msg.payload.request_id);
        room.pendingAcks.delete(msg.payload.request_id);
        if (viewerId) room.viewers.get(viewerId)?.send(msg);
        return;
      }
      default:
        throw new ForbiddenMessage(`a camera does not send ${msg.type}`);
    }
  }
  if (msg.type !== "camera.set") throw new ForbiddenMessage(`a viewer does not send ${msg.type}`);
  if (!room.camera) {
    from.send(
      message("camera.ack", room.tableId, { request_id: msg.id, ok: false, error: "camera_unavailable" }),
    );
    return;
  }
  // Several viewers may change the same parameter: the last one wins (SPEC 5.3); the camera reports camera.state.
  room.pendingAcks.set(msg.id, from.id);
  if (room.pendingAcks.size > 1000) room.pendingAcks.delete(room.pendingAcks.keys().next().value as string);
  room.camera.send(msg);
}

/** What a viewer gets right after joining: the room's state, so its UI is complete before anything changes. */
export function welcome(room: Room, viewer: Peer): void {
  viewer.send(room.licenseStatus());
  viewer.send(room.streamStatus());
  for (const cached of [room.cache.capabilities, room.cache.state, room.cache.telemetry]) {
    if (cached) viewer.send(cached);
  }
  if (room.producer) {
    viewer.send(message("signaling.new_producer", room.tableId, { producer_id: room.producer.id, kind: "video" }));
  }
}
