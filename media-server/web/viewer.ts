// The club's PC in a browser until the Windows client (stage 6). Signs in with the client's activation key,
// lists the tables, plays a table's camera live, shows the phone's telemetry and alerts, changes the camera's
// settings with the time until the camera confirmed each one (SPEC 6.5), and shows a pairing code with its QR
// for a new phone. mediasoup-client's Device API only, never hand-built SDP (CLAUDE.md); the messages are
// contracts/'s, nothing new.
import { Device, type types } from "mediasoup-client";
import qrcode from "qrcode-generator";

const TEXT = {
  ru: {
    title: "PokerCam — просмотр",
    setupTitle: "Подключение компьютера",
    setupServer: "Адрес сервера",
    setupKey: "Ключ активации клиента",
    setupName: "Название этого компьютера",
    setupDefaultName: "Браузер",
    setupConnect: "Подключить",
    tablesTitle: "Столы",
    table: "Стол {n}",
    cameraOnline: "камера в эфире",
    cameraOffline: "камеры нет",
    noTables: "У клиента нет столов.",
    changeTable: "Другой стол",
    signOut: "Выйти",
    pairPhone: "Привязать телефон",
    pairTitle: "Привязка телефона к столу {n}",
    pairHint: "Наведите камеру приложения на QR-код или введите вручную: сервер {api}, код ниже.",
    pairExpires: "Код действует до {time}.",
    close: "Закрыть",
    connecting: "Подключение…",
    reconnecting: "Переподключение…",
    live: "LIVE",
    noCamera: "Камера стола не транслирует",
    licenseGrace: "Оплата просрочена: доступ до {date}",
    licenseBlocked: "Доступ клуба заблокирован: продлите оплату",
    secReceive: "Приём на этом компьютере",
    secPhone: "Телефон",
    secCamera: "Камера",
    secAlerts: "Предупреждения",
    resolution: "Разрешение",
    codec: "Кодек",
    fps: "Кадры",
    freezes: "Замирания",
    lost: "Потеряно пакетов",
    bitrate: "Битрейт",
    dropped: "Пропущено кадров",
    battery: "Заряд",
    charging: "заряжается",
    temperature: "Температура",
    thermal: "Нагрев",
    network: "Сеть",
    unitFps: "{v} к/с",
    unitKbps: "{v} кбит/с",
    unitMs: "{v} мс",
    noData: "—",
    noAlerts: "Нет",
    unsupported: "не поддерживается",
    mode_auto: "авто",
    mode_manual: "вручную",
    mode_preset: "пресет",
    ackWait: "ждём камеру…",
    ackOk: "применено за {ms} мс",
    ackUnconfirmed: "отправлено, камера не подтвердила за {ms} мс",
    ackFail: "отказ: {code}",
    param_focus: "Фокус",
    param_iso: "ISO",
    param_exposure: "Выдержка",
    param_brightness: "Яркость",
    param_contrast: "Контраст",
    param_white_balance: "Баланс белого",
    param_zoom: "Зум",
    preset_incandescent: "лампа накаливания",
    preset_fluorescent: "люминесцентная",
    preset_warm_fluorescent: "тёплая люминесцентная",
    preset_daylight: "дневной свет",
    preset_cloudy_daylight: "облачно",
    preset_twilight: "сумерки",
    preset_shade: "тень",
    alertOverheating: "Телефон нагрелся: битрейт снижен",
    alertOverheatingWarning: "Телефон нагрелся: битрейт снижен",
    alertOverheatingCritical: "Телефон перегрет: битрейт снижен до минимума",
    alertCooledDown: "Телефон остыл: битрейт восстановлен",
    alertLowBattery: "Мало заряда: подключите зарядку",
    alertBatteryCritical: "Заряд почти закончился",
    errInvalidKey: "Неверный ключ активации.",
    errUnreachable: "Сервер недоступен: проверьте адрес.",
    errRevoked: "Этот компьютер отключён в админке: подключите его заново.",
    errRoomFull: "К столу уже подключён другой зритель.",
    errLicense: "Доступ клуба заблокирован: продлите оплату.",
    errGeneric: "Ошибка: {code}",
  },
  en: {
    title: "PokerCam — viewer",
    setupTitle: "Connect this computer",
    setupServer: "Server address",
    setupKey: "Client activation key",
    setupName: "This computer's name",
    setupDefaultName: "Browser",
    setupConnect: "Connect",
    tablesTitle: "Tables",
    table: "Table {n}",
    cameraOnline: "camera on air",
    cameraOffline: "no camera",
    noTables: "The client has no tables.",
    changeTable: "Another table",
    signOut: "Sign out",
    pairPhone: "Pair a phone",
    pairTitle: "Pair a phone with table {n}",
    pairHint: "Point the app's camera at the QR code or enter by hand: server {api}, the code below.",
    pairExpires: "The code is valid until {time}.",
    close: "Close",
    connecting: "Connecting…",
    reconnecting: "Reconnecting…",
    live: "LIVE",
    noCamera: "The table's camera is not streaming",
    licenseGrace: "Payment overdue: access until {date}",
    licenseBlocked: "The club's access is blocked: renew the payment",
    secReceive: "Received on this computer",
    secPhone: "Phone",
    secCamera: "Camera",
    secAlerts: "Alerts",
    resolution: "Resolution",
    codec: "Codec",
    fps: "Frame rate",
    freezes: "Freezes",
    lost: "Packets lost",
    bitrate: "Bitrate",
    dropped: "Dropped frames",
    battery: "Battery",
    charging: "charging",
    temperature: "Temperature",
    thermal: "Heat",
    network: "Network",
    unitFps: "{v} fps",
    unitKbps: "{v} kbit/s",
    unitMs: "{v} ms",
    noData: "—",
    noAlerts: "None",
    unsupported: "not supported",
    mode_auto: "auto",
    mode_manual: "manual",
    mode_preset: "preset",
    ackWait: "waiting for the camera…",
    ackOk: "applied in {ms} ms",
    ackUnconfirmed: "sent, the camera did not confirm within {ms} ms",
    ackFail: "refused: {code}",
    param_focus: "Focus",
    param_iso: "ISO",
    param_exposure: "Exposure",
    param_brightness: "Brightness",
    param_contrast: "Contrast",
    param_white_balance: "White balance",
    param_zoom: "Zoom",
    preset_incandescent: "incandescent",
    preset_fluorescent: "fluorescent",
    preset_warm_fluorescent: "warm fluorescent",
    preset_daylight: "daylight",
    preset_cloudy_daylight: "cloudy",
    preset_twilight: "twilight",
    preset_shade: "shade",
    alertOverheating: "The phone is hot: bitrate lowered",
    alertOverheatingWarning: "The phone is hot: bitrate lowered",
    alertOverheatingCritical: "The phone is overheating: bitrate at its minimum",
    alertCooledDown: "The phone cooled down: bitrate restored",
    alertLowBattery: "Battery low: plug in the charger",
    alertBatteryCritical: "The battery is almost empty",
    errInvalidKey: "Wrong activation key.",
    errUnreachable: "The server cannot be reached: check the address.",
    errRevoked: "This computer was disconnected in the admin panel: connect it again.",
    errRoomFull: "Another viewer is already watching this table.",
    errLicense: "The club's access is blocked: renew the payment.",
    errGeneric: "Error: {code}",
  },
} as const;

type TextKey = keyof (typeof TEXT)["ru"];
const lang: keyof typeof TEXT = navigator.language.toLowerCase().startsWith("ru") ? "ru" : "en";

function t(key: TextKey, vars: Record<string, string | number> = {}): string {
  return TEXT[lang][key].replace(/\{(\w+)\}/g, (_, name: string) => String(vars[name] ?? ""));
}

/** A key from the camera or the server (a parameter, a preset, an alert) with its own text, or as it is. */
function tOr(key: string, fallback: string): string {
  return key in TEXT[lang] ? t(key as TextKey) : fallback;
}

/**
 * A random UUID v4. crypto.randomUUID exists only in secure contexts (https, localhost), and a club's PC opens
 * this page at http://IP:3000; getRandomValues works everywhere.
 */
function uuid(): string {
  const b = crypto.getRandomValues(new Uint8Array(16));
  b[6] = ((b[6] ?? 0) & 0x0f) | 0x40;
  b[8] = ((b[8] ?? 0) & 0x3f) | 0x80;
  const hex = [...b].map((byte) => byte.toString(16).padStart(2, "0")).join("");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

// ---- What the browser remembers -------------------------------------------------------------------------

interface Saved {
  api: string;
  machineId: string;
  refreshToken?: string;
  tableId?: string;
}

const STORE_KEY = "pokercam.viewer";

function load(): Saved {
  try {
    const saved = JSON.parse(localStorage.getItem(STORE_KEY) ?? "null") as Saved | null;
    if (saved) return saved;
  } catch {
    // Private mode or a broken value: start over.
  }
  return { api: `${location.protocol}//${location.hostname}:8000`, machineId: uuid() };
}

let saved = load();

function save(): void {
  try {
    localStorage.setItem(STORE_KEY, JSON.stringify(saved));
  } catch {
    // Without storage the page asks for the key again next time.
  }
}

// ---- Backend REST (contracts/rest) -----------------------------------------------------------------------

class ApiError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
  ) {
    super(code);
  }
}

async function api<T>(path: string, init: { method?: string; body?: unknown; token?: string } = {}): Promise<T> {
  const headers: Record<string, string> = {};
  if (init.body !== undefined) headers["content-type"] = "application/json";
  if (init.token) headers.authorization = `Bearer ${init.token}`;
  let response: Response;
  try {
    response = await fetch(`${saved.api}/api/v1${path}`, {
      method: init.method ?? "GET",
      headers,
      ...(init.body === undefined ? {} : { body: JSON.stringify(init.body) }),
    });
  } catch {
    throw new ApiError(0, "unreachable");
  }
  const body = (await response.json().catch(() => null)) as { detail?: { code?: string } } | null;
  if (!response.ok) throw new ApiError(response.status, body?.detail?.code ?? `http_${String(response.status)}`);
  return body as T;
}

interface TokenResponse {
  access_token: string;
  media_url: string;
}

interface TableItem {
  id: string;
  name: string;
  number: number;
  camera_online: boolean;
}

const accessToken = async (tableId?: string): Promise<TokenResponse> =>
  api<TokenResponse>("/auth/token", {
    method: "POST",
    body: { refresh_token: saved.refreshToken, ...(tableId ? { table_id: tableId } : {}) },
  });

function errorText(error: unknown): string {
  if (!(error instanceof ApiError)) return t("errGeneric", { code: String(error) });
  switch (error.code) {
    case "invalid_activation_key":
      return t("errInvalidKey");
    case "unreachable":
      return t("errUnreachable");
    case "invalid_refresh_token":
    case "access_revoked":
      return t("errRevoked");
    case "license_expired":
    case "license_suspended":
    case "no_license":
    case "license_blocked":
      return t("errLicense");
    case "room_full":
      return t("errRoomFull");
    default:
      return t("errGeneric", { code: error.code });
  }
}

// ---- Tiny DOM helpers ------------------------------------------------------------------------------------

const app = document.getElementById("app") as HTMLElement;

function h<K extends keyof HTMLElementTagNameMap>(
  tag: K,
  props: Partial<HTMLElementTagNameMap[K]> & { className?: string } = {},
  ...children: (Node | string)[]
): HTMLElementTagNameMap[K] {
  const element = Object.assign(document.createElement(tag), props);
  element.append(...children);
  return element;
}

/** A number or string from a message or a stats report, or the "no data" dash. */
function text(value: unknown, fallback: string = t("noData")): string {
  return typeof value === "number" || typeof value === "string" ? String(value) : fallback;
}

function rows(list: HTMLDListElement, entries: [string, string][]): void {
  if (!entries.length) {
    list.replaceChildren(h("dt", { className: "muted" }, t("noData")));
    return;
  }
  list.replaceChildren(...entries.flatMap(([label, value]) => [h("dt", {}, label), h("dd", {}, value)]));
}

function header(...actions: HTMLElement[]): HTMLElement {
  return h("header", {}, h("h1", {}, t("title")), ...actions);
}

// ---- Screens ---------------------------------------------------------------------------------------------

let current: Watch | undefined;

function show(...nodes: Node[]): void {
  current?.stop();
  current = undefined;
  document.title = t("title");
  app.replaceChildren(...nodes);
}

function signOut(message?: string): void {
  saved = { api: saved.api, machineId: saved.machineId };
  save();
  setup(message);
}

function setup(message?: string): void {
  const server = h("input", { value: saved.api, required: true });
  const key = h("input", { required: true, autocomplete: "off" });
  const name = h("input", { value: t("setupDefaultName"), required: true });
  const error = h("p", { className: "error" }, message ?? "");
  const submit = h("button", { className: "primary", type: "submit" }, t("setupConnect"));
  const form = h(
    "form",
    { className: "center" },
    h("h2", {}, t("setupTitle")),
    h("label", {}, t("setupServer"), server),
    h("label", {}, t("setupKey"), key),
    h("label", {}, t("setupName"), name),
    submit,
    error,
  );
  form.addEventListener("submit", (event) => {
    event.preventDefault();
    submit.disabled = true;
    saved.api = server.value.trim().replace(/\/+$/, "");
    api<{ refresh_token: string }>("/viewer/activate", {
      method: "POST",
      body: { activation_key: key.value.trim(), machine_id: saved.machineId, name: name.value.trim() },
    }).then(
      (activated) => {
        saved.refreshToken = activated.refresh_token;
        save();
        void tables();
      },
      (failure: unknown) => {
        submit.disabled = false;
        error.textContent = errorText(failure);
      },
    );
  });
  show(header(), form);
  key.focus();
}

async function tables(): Promise<void> {
  let list: TableItem[];
  try {
    const token = await accessToken();
    list = (await api<{ tables: TableItem[] }>("/tables", { token: token.access_token })).tables;
  } catch (error) {
    if (error instanceof ApiError && error.status === 401) {
      signOut(errorText(error));
      return;
    }
    show(header(signOutButton()), h("div", { className: "center" }, h("p", { className: "error" }, errorText(error))));
    return;
  }
  const remembered = list.find((table) => table.id === saved.tableId);
  const only = list.length === 1 ? list[0] : undefined;
  const chosen = remembered ?? only;
  if (chosen) {
    watch(chosen, list.length > 1);
    return;
  }
  const buttons = list.map((table) => {
    const button = h(
      "button",
      {},
      h("span", {}, t("table", { n: table.number })),
      h("span", { className: "muted" }, table.camera_online ? t("cameraOnline") : t("cameraOffline")),
    );
    button.addEventListener("click", () => {
      watch(table, true);
    });
    return button;
  });
  show(
    header(signOutButton()),
    h(
      "div",
      { className: "center" },
      h("h2", {}, t("tablesTitle")),
      list.length ? h("div", { className: "tables" }, ...buttons) : h("p", { className: "muted" }, t("noTables")),
    ),
  );
}

function signOutButton(): HTMLButtonElement {
  const button = h("button", {}, t("signOut"));
  button.addEventListener("click", () => {
    signOut();
  });
  return button;
}

function watch(table: TableItem, canChange: boolean): void {
  saved.tableId = table.id;
  save();
  const pair = h("button", {}, t("pairPhone"));
  const change = h("button", {}, t("changeTable"));
  change.addEventListener("click", () => {
    delete saved.tableId;
    save();
    void tables();
  });
  const session = new Watch(table);
  pair.addEventListener("click", () => void session.showPairing());
  show(header(pair, ...(canChange ? [change] : []), signOutButton()), session.root);
  current = session;
  session.start();
}

// ---- Watching a table ------------------------------------------------------------------------------------

interface Envelope {
  type: string;
  id: string;
  ts: number;
  table_id: string;
  payload: Record<string, unknown>;
}

interface Control {
  mode: string;
  value?: number;
  preset?: string;
}

interface Capability {
  supported: boolean;
  modes: string[];
  presets: string[];
  min?: number;
  max?: number;
  step?: number;
  current?: Control;
}

const PARAMS = ["focus", "iso", "exposure", "brightness", "contrast", "white_balance", "zoom"] as const;
const RECONNECT_MS = 2000;
/** The phone answers camera.set after the camera confirmed it, or after 2 s without a confirmation. */
const CONFIRM_MS = 2000;

/** A value as the camera means it: exposure in nanoseconds is shown in milliseconds. */
function shown(param: string, value: number): string {
  if (param === "exposure") return t("unitMs", { v: (value / 1e6).toFixed(1) });
  if (param === "zoom") return `${value.toFixed(1)}×`;
  if (param === "white_balance") return `${String(Math.round(value))} K`;
  return String(Math.round(value * 100) / 100);
}

class ParamRow {
  readonly root = h("div", { className: "param" });
  private readonly mode = h("select");
  private readonly slider = h("input", { type: "range" });
  private readonly preset = h("select");
  private readonly value = h("span", { className: "muted" });
  private readonly ack = h("span", { className: "ack muted" });

  constructor(
    readonly param: string,
    private readonly cap: Capability,
    private readonly send: (param: string, control: Control) => void,
  ) {
    const label = h("strong", {}, tOr(`param_${param}`, param));
    if (!cap.supported) {
      this.root.append(h("div", { className: "row" }, label, h("span", { className: "muted" }, t("unsupported"))));
      return;
    }
    for (const mode of cap.modes) this.mode.append(h("option", { value: mode }, tOr(`mode_${mode}`, mode)));
    for (const preset of cap.presets) this.preset.append(h("option", { value: preset }, tOr(`preset_${preset}`, preset)));
    Object.assign(this.slider, { min: String(cap.min ?? 0), max: String(cap.max ?? 1), step: String(cap.step ?? "any") });
    this.root.append(h("div", { className: "row" }, label, this.value, this.mode), this.slider, this.preset, this.ack);
    this.mode.addEventListener("change", () => {
      this.layout();
      this.apply();
    });
    this.slider.addEventListener("input", () => {
      this.value.textContent = shown(param, Number(this.slider.value));
    });
    this.slider.addEventListener("change", () => {
      this.apply();
    });
    this.preset.addEventListener("change", () => {
      this.apply();
    });
    this.update(cap.current ?? { mode: cap.modes[0] ?? "auto" });
  }

  /** The camera's current setting (camera.state), unless the user is moving this slider right now. */
  update(control: Control): void {
    if (!this.cap.supported || document.activeElement === this.slider) return;
    this.mode.value = control.mode;
    if (control.value !== undefined) this.slider.value = String(control.value);
    if (control.preset) this.preset.value = control.preset;
    this.layout();
  }

  acked(text: string, ok: boolean | null): void {
    this.ack.textContent = text;
    this.ack.className = `ack ${ok === null ? "muted" : ok ? "ok" : "bad"}`;
  }

  private layout(): void {
    const manual = this.mode.value === "manual";
    this.slider.hidden = !manual;
    this.preset.hidden = this.mode.value !== "preset";
    this.value.textContent = manual ? shown(this.param, Number(this.slider.value)) : "";
  }

  private apply(): void {
    const mode = this.mode.value;
    const control: Control =
      mode === "manual"
        ? { mode, value: Number(this.slider.value) }
        : mode === "preset"
          ? { mode, preset: this.preset.value }
          : { mode };
    this.acked(t("ackWait"), null);
    this.send(this.param, control);
  }
}

class Watch {
  readonly root = h("div", { className: "watch" });
  private readonly video = h("video", { muted: true, autoplay: true, playsInline: true });
  private readonly chip = h("span", { className: "chip" }, t("connecting"));
  private readonly banner = h("div", { className: "banner", hidden: true });
  private readonly receive = h("dl");
  private readonly phone = h("dl");
  private readonly controls = h("div");
  private readonly alerts = h("div", { className: "muted" }, t("noAlerts"));
  private readonly rows = new Map<string, ParamRow>();
  private readonly sent = new Map<string, { param: string; at: number }>();
  private readonly pending = new Map<string, { resolve: (p: Record<string, unknown>) => void; reject: (e: Error) => void }>();
  private ws: WebSocket | undefined;
  private device: Device | undefined;
  private transport: types.Transport | undefined;
  private consumer: types.Consumer | undefined;
  private stopped = false;
  private producerAnnounced = false;
  /** Why the last connection failed (room full, license, unreachable): shown, and retried less often. */
  private error: string | null = null;
  private timers: number[] = [];
  private license: { status: string; grace_until?: number } = { status: "active" };
  private stream = "offline";
  private alertList: { text: string; level: string; at: Date }[] = [];

  constructor(private readonly table: TableItem) {
    this.root.append(
      h("div", { className: "stage" }, this.video, this.chip, this.banner),
      h(
        "div",
        { className: "side" },
        h("section", {}, h("h2", {}, t("table", { n: table.number })), this.receive),
        h("section", {}, h("h2", {}, t("secPhone")), this.phone),
        h("section", {}, h("h2", {}, t("secCamera")), this.controls),
        h("section", {}, h("h2", {}, t("secAlerts")), this.alerts),
      ),
    );
    rows(this.receive, []);
    rows(this.phone, []);
  }

  start(): void {
    void this.connect();
    this.timers.push(window.setInterval(() => void this.refreshStats(), 1000));
  }

  stop(): void {
    this.stopped = true;
    for (const timer of this.timers) window.clearInterval(timer);
    this.ws?.close();
    this.transport?.close();
  }

  async showPairing(): Promise<void> {
    const dialog = h("dialog");
    const closeButton = h("button", {}, t("close"));
    closeButton.addEventListener("click", () => {
      dialog.close();
      dialog.remove();
    });
    try {
      const token = await accessToken();
      const code = await api<{ code: string; expires_at: string; qr_payload: string }>(
        `/tables/${this.table.id}/pairing-code`,
        { method: "POST", token: token.access_token },
      );
      const qr = qrcode(0, "M");
      qr.addData(code.qr_payload);
      qr.make();
      const picture = h("div", { className: "qr" });
      picture.innerHTML = qr.createSvgTag({ cellSize: 8, margin: 2, scalable: true });
      dialog.append(
        h("h2", {}, t("pairTitle", { n: this.table.number })),
        picture,
        h("div", { className: "code" }, code.code),
        h("p", { className: "muted" }, t("pairHint", { api: saved.api })),
        h("p", { className: "muted" }, t("pairExpires", { time: new Date(code.expires_at).toLocaleTimeString() })),
        closeButton,
      );
    } catch (error) {
      dialog.append(h("p", { className: "error" }, errorText(error)), closeButton);
    }
    document.body.append(dialog);
    dialog.showModal();
  }

  private status(): void {
    const live = this.stream === "live" && this.consumer !== undefined;
    this.chip.textContent = live ? t("live") : this.ws?.readyState === WebSocket.OPEN ? t("noCamera") : t("reconnecting");
    this.chip.className = `chip${live ? " live" : ""}`;
    const blocked = this.license.status === "blocked";
    const grace = this.license.status === "grace" && this.license.grace_until !== undefined;
    this.banner.hidden = !this.error && !blocked && !grace;
    this.banner.className = `banner${this.error || blocked ? " critical" : ""}`;
    this.banner.textContent =
      this.error ??
      (blocked
        ? t("licenseBlocked")
        : grace
          ? t("licenseGrace", { date: new Date(this.license.grace_until ?? 0).toLocaleString() })
          : "");
  }

  private retry(): void {
    if (!this.stopped) window.setTimeout(() => void this.connect(), this.error ? RECONNECT_MS * 5 : RECONNECT_MS);
  }

  private async connect(): Promise<void> {
    if (this.stopped) return;
    this.status();
    let token: TokenResponse;
    try {
      token = await accessToken(this.table.id);
    } catch (error) {
      if (error instanceof ApiError && error.status === 401) {
        signOut(errorText(error));
        return;
      }
      this.fail(error);
      this.retry();
      return;
    }
    const ws = new WebSocket(token.media_url);
    this.ws = ws;
    ws.onmessage = (event: MessageEvent<string>) => {
      this.onMessage(JSON.parse(event.data) as Envelope);
    };
    ws.onclose = () => {
      if (this.ws !== ws) return;
      this.transport?.close();
      this.transport = undefined;
      this.consumer = undefined;
      this.device = undefined;
      this.producerAnnounced = false;
      this.video.srcObject = null;
      this.status();
      this.retry();
    };
    ws.onopen = () => {
      void this.join(token.access_token).catch((error: unknown) => {
        this.fail(error);
        ws.close();
      });
    };
  }

  private fail(error: unknown): void {
    this.error = errorText(error);
    this.status();
  }

  private async join(token: string): Promise<void> {
    await this.request("signaling.join", { token });
    const device = await Device.factory();
    const caps = await this.request("signaling.get_router_rtp_capabilities");
    await device.load({ routerRtpCapabilities: caps.rtp_capabilities as types.RtpCapabilities });
    this.device = device;
    this.error = null;
    this.status();
    // welcome() announced the camera before the device was loaded: consume it now.
    if (this.producerAnnounced) await this.consume();
  }

  private send(type: string, payload: Record<string, unknown>): string {
    const msg: Envelope = { type, id: uuid(), ts: Date.now(), table_id: this.table.id, payload };
    this.ws?.send(JSON.stringify(msg));
    return msg.id;
  }

  private request(type: string, payload: Record<string, unknown> = {}): Promise<Record<string, unknown>> {
    const id = this.send(type, payload);
    return new Promise((resolve, reject) => this.pending.set(id, { resolve, reject }));
  }

  private onMessage(msg: Envelope): void {
    const requestId = msg.payload.request_id;
    const waiting = typeof requestId === "string" ? this.pending.get(requestId) : undefined;
    if (waiting && (msg.type.endsWith(".result") || msg.type === "signaling.error")) {
      this.pending.delete(requestId as string);
      if (msg.type === "signaling.error") waiting.reject(new ApiError(0, String(msg.payload.code)));
      else waiting.resolve(msg.payload);
      return;
    }
    switch (msg.type) {
      case "license.status":
        this.license = msg.payload as { status: string; grace_until?: number };
        this.status();
        return;
      case "stream.status":
        this.stream = String(msg.payload.status);
        this.status();
        return;
      case "signaling.new_producer":
        this.producerAnnounced = true;
        if (this.device) void this.consume().catch((error: unknown) => { this.fail(error); });
        return;
      case "signaling.consumer_closed":
        this.consumer?.close();
        this.consumer = undefined;
        this.producerAnnounced = false;
        this.video.srcObject = null;
        this.status();
        return;
      case "camera.capabilities":
        this.capabilities((msg.payload as { params: Record<string, Capability> }).params);
        return;
      case "camera.state":
        for (const [param, control] of Object.entries((msg.payload as { controls: Record<string, Control> }).controls)) {
          this.rows.get(param)?.update(control);
        }
        return;
      case "camera.ack":
        this.acked(msg.payload as { request_id: string; ok: boolean; error?: string });
        return;
      case "device.telemetry":
        this.telemetry(msg.payload);
        return;
      case "device.alert":
        this.alert(msg.payload as { level: string; message_key: string });
        return;
    }
  }

  private async consume(): Promise<void> {
    const device = this.device;
    if (!device) return;
    if (!this.transport) {
      const p = await this.request("signaling.create_transport", { direction: "recv" });
      const transport = device.createRecvTransport({
        id: p.transport_id as string,
        iceParameters: p.ice_parameters as types.IceParameters,
        iceCandidates: p.ice_candidates as types.IceCandidate[],
        dtlsParameters: p.dtls_parameters as types.DtlsParameters,
      });
      transport.on("connect", ({ dtlsParameters }, done, fail) => {
        this.request("signaling.connect_transport", { transport_id: transport.id, dtls_parameters: dtlsParameters }).then(
          () => {
            done();
          },
          fail,
        );
      });
      this.transport = transport;
    }
    const transport = this.transport;
    const p = await this.request("signaling.consume", {
      transport_id: transport.id,
      rtp_capabilities: device.recvRtpCapabilities,
    });
    this.consumer?.close();
    const consumer = await transport.consume({
      id: p.consumer_id as string,
      producerId: p.producer_id as string,
      kind: "video",
      rtpParameters: p.rtp_parameters as types.RtpParameters,
    });
    this.consumer = consumer;
    this.video.srcObject = new MediaStream([consumer.track]);
    await this.request("signaling.resume", { consumer_id: consumer.id });
    this.status();
  }

  private capabilities(params: Record<string, Capability>): void {
    this.rows.clear();
    const send = (param: string, control: Control): void => {
      const id = this.send("camera.set", { param, control });
      this.sent.set(id, { param, at: performance.now() });
    };
    for (const param of PARAMS) {
      const cap = params[param];
      if (cap) this.rows.set(param, new ParamRow(param, cap, send));
    }
    this.controls.replaceChildren(...[...this.rows.values()].map((row) => row.root));
  }

  private acked(ack: { request_id: string; ok: boolean; error?: string }): void {
    const sent = this.sent.get(ack.request_id);
    if (!sent) return;
    this.sent.delete(ack.request_id);
    const ms = Math.round(performance.now() - sent.at);
    const row = this.rows.get(sent.param);
    if (!ack.ok) row?.acked(t("ackFail", { code: ack.error ?? "?" }), false);
    else if (ms >= CONFIRM_MS) row?.acked(t("ackUnconfirmed", { ms }), false);
    else row?.acked(t("ackOk", { ms }), true);
  }

  private telemetry(p: Record<string, unknown>): void {
    const stream = (p.stream ?? {}) as { fps?: number; bitrate_kbps?: number; dropped_frames?: number };
    const network = (p.network ?? {}) as { type?: string; rssi?: number; rtt_ms?: number };
    const battery = `${text(p.battery_pct)} %${p.charging === true ? `, ${t("charging")}` : ""}`;
    rows(this.phone, [
      [t("fps"), t("unitFps", { v: Math.round(stream.fps ?? 0) })],
      [t("bitrate"), t("unitKbps", { v: stream.bitrate_kbps ?? 0 })],
      [t("dropped"), String(stream.dropped_frames ?? 0)],
      [t("temperature"), p.temp_c === undefined ? t("noData") : `${text(p.temp_c)} °C`],
      [t("thermal"), text(p.thermal_status)],
      [t("battery"), battery],
      [
        t("network"),
        [network.type, network.rssi === undefined ? "" : `${String(network.rssi)} dBm`, network.rtt_ms === undefined ? "" : t("unitMs", { v: network.rtt_ms })]
          .filter(Boolean)
          .join(", "),
      ],
    ]);
  }

  private alert(p: { level: string; message_key: string }): void {
    this.alertList.unshift({ text: tOr(p.message_key, p.message_key), level: p.level, at: new Date() });
    this.alertList = this.alertList.slice(0, 5);
    this.alerts.replaceChildren(
      ...this.alertList.map((a) =>
        h("div", { className: a.level === "critical" ? "error" : "" }, `${a.at.toLocaleTimeString()} — ${a.text}`),
      ),
    );
  }

  private async refreshStats(): Promise<void> {
    const consumer = this.consumer;
    if (!consumer) {
      rows(this.receive, []);
      return;
    }
    const reports = [...(await consumer.getStats()).values()] as Record<string, unknown>[];
    const rtp = reports.find((r) => r.type === "inbound-rtp");
    if (!rtp) return;
    const codec = reports.find((r) => r.type === "codec" && r.id === rtp.codecId);
    rows(this.receive, [
      [t("resolution"), `${text(rtp.frameWidth, "0")}×${text(rtp.frameHeight, "0")}`],
      [t("codec"), text(codec?.mimeType).replace("video/", "")],
      [t("fps"), t("unitFps", { v: Math.round(Number(rtp.framesPerSecond ?? 0)) })],
      [t("freezes"), text(rtp.freezeCount, "0")],
      [t("lost"), text(rtp.packetsLost, "0")],
    ]);
  }
}

// ---- Start -----------------------------------------------------------------------------------------------

document.documentElement.lang = lang;
if (saved.refreshToken) void tables();
else setup();
