import type { Logger } from "pino";
import type { InternalCameraPresenceRequest, InternalJwtKeyResponse, InternalLicenseResponse } from "./contracts/types.js";

/** media-server's side of the backend's internal API (/api/v1/internal, X-Internal-Token). */
export class BackendClient {
  constructor(
    private readonly baseUrl: string,
    private readonly token: string,
    private readonly log: Logger,
  ) {}

  private async call(method: string, path: string, body?: unknown): Promise<Response> {
    const response = await fetch(`${this.baseUrl}/api/v1/internal${path}`, {
      method,
      headers: { "X-Internal-Token": this.token, ...(body === undefined ? {} : { "Content-Type": "application/json" }) },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
      signal: AbortSignal.timeout(5000),
    });
    if (!response.ok) throw new Error(`backend ${method} ${path}: ${String(response.status)}`);
    return response;
  }

  async jwtKey(): Promise<InternalJwtKeyResponse> {
    return (await (await this.call("GET", "/jwt-key")).json()) as InternalJwtKeyResponse;
  }

  async tableLicense(tableId: string): Promise<InternalLicenseResponse> {
    return (await (await this.call("GET", `/tables/${tableId}/license`)).json()) as InternalLicenseResponse;
  }

  /** Fire and forget: a failed report only makes the PC's table list stale. */
  reportCamera(tableId: string, online: boolean): void {
    const body: InternalCameraPresenceRequest = { online };
    this.call("PUT", `/tables/${tableId}/camera`, body).catch((error: unknown) => {
      this.log.warn({ err: error, table_id: tableId }, "could not report camera presence");
    });
  }

  /** Tells the backend that no camera publishes after a restart; retried until the backend answers. */
  async announceStart(retryMs = 5000): Promise<void> {
    for (;;) {
      try {
        await this.call("POST", "/media-server/started");
        return;
      } catch (error) {
        this.log.warn({ err: error }, "backend not reachable yet, retrying");
        await new Promise((resolve) => setTimeout(resolve, retryMs));
      }
    }
  }
}
