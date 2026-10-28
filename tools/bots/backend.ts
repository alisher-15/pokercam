// The backend's public API as the real apps use it: activation, pairing, tokens.
import type {
  DevicePairResponse,
  PairingCodeResponse,
  TableListResponse,
  TokenResponse,
  ViewerActivateResponse,
} from "../../media-server/src/contracts/types.ts";

export class Backend {
  private readonly url: string;

  constructor(url: string) {
    this.url = url;
  }

  private async call<T>(method: string, path: string, body?: unknown, token?: string): Promise<T> {
    const response = await fetch(`${this.url}/api/v1${path}`, {
      method,
      headers: {
        ...(body === undefined ? {} : { "Content-Type": "application/json" }),
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
      },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    });
    if (!response.ok) throw new Error(`${method} ${path}: ${String(response.status)} ${await response.text()}`);
    return (await response.json()) as T;
  }

  activate(key: string, machineId: string): Promise<ViewerActivateResponse> {
    return this.call("POST", "/viewer/activate", { activation_key: key, machine_id: machineId, name: machineId });
  }

  async token(refreshToken: string, tableId?: string): Promise<string> {
    const body = { refresh_token: refreshToken, ...(tableId ? { table_id: tableId } : {}) };
    return (await this.call<TokenResponse>("POST", "/auth/token", body)).access_token;
  }

  tables(access: string): Promise<TableListResponse> {
    return this.call("GET", "/tables", undefined, access);
  }

  pairingCode(access: string, tableId: string): Promise<PairingCodeResponse> {
    return this.call("POST", `/tables/${tableId}/pairing-code`, undefined, access);
  }

  pair(code: string, androidId: string): Promise<DevicePairResponse> {
    return this.call("POST", "/device/pair", { code, model: "Fake camera (Chromium)", android_id: androidId });
  }
}

export interface Club {
  tableId: string;
  /** An access token for the table from the club's bot PC; the room counts connections, so one PC serves every bot viewer. */
  viewerToken: () => Promise<string>;
  /** Pairs a fresh fake phone to the table (the old one is revoked) and returns its access token. */
  cameraToken: () => Promise<string>;
}

/** A club's table, reached with the club's activation key the way the Windows app does. */
export async function club(backendUrl: string, key: string, tableNumber = 1): Promise<Club> {
  const backend = new Backend(backendUrl);
  // One activation per run: the backend allows 5 activations a minute from one address.
  const pc = await backend.activate(key, "bot-pc");
  const table = (await backend.tables(await backend.token(pc.refresh_token))).tables.find((t) => t.number === tableNumber);
  if (!table) throw new Error(`no table number ${String(tableNumber)}`);
  return {
    tableId: table.id,
    viewerToken: () => backend.token(pc.refresh_token, table.id),
    cameraToken: async () => {
      const code = await backend.pairingCode(await backend.token(pc.refresh_token), table.id);
      const phone = await backend.pair(code.code, `fake-camera-${String(Date.now())}`);
      return backend.token(phone.refresh_token);
    },
  };
}
