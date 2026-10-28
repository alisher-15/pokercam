import { Ajv, type ValidateFunction } from "ajv";
import addFormatsModule from "ajv-formats";
import { schemas } from "./schemas.js";
import type { Message } from "./messages.js";

// ajv-formats is CommonJS; its default export arrives wrapped under nodenext resolution.
const addFormats = addFormatsModule as unknown as (ajv: Ajv) => Ajv;

const BASE_ID = "https://contracts.invalid/";
const ajv = new Ajv({ strict: true, strictRequired: false, allErrors: true });
addFormats(ajv);
for (const [rel, schema] of Object.entries(schemas)) ajv.addSchema({ ...schema, $id: BASE_ID + rel });

function compiled(rel: string): ValidateFunction {
  const validate = ajv.getSchema(BASE_ID + rel);
  if (!validate) throw new Error(`no schema ${rel}`);
  return validate;
}

const envelope = compiled("ws/envelope.json");
const byType = new Map<string, ValidateFunction>(
  Object.entries(schemas)
    .filter(([rel]) => rel.startsWith("ws/") && rel !== "ws/envelope.json")
    .map(([rel]) => [rel.slice(rel.lastIndexOf("/") + 1, -".json".length), compiled(rel)]),
);

export type ParseResult = { ok: true; message: Message } | { ok: false; error: string };

/** Checks a decoded WebSocket message: first the envelope, then the schema of its type. */
export function validateMessage(data: unknown): ParseResult {
  if (!envelope(data)) return { ok: false, error: `envelope: ${ajv.errorsText(envelope.errors)}` };
  const type = (data as { type: string }).type;
  const validate = byType.get(type);
  if (!validate) return { ok: false, error: `unknown message type ${type}` };
  if (!validate(data)) return { ok: false, error: `${type}: ${ajv.errorsText(validate.errors)}` };
  return { ok: true, message: data as Message };
}

/** Decodes and checks a WebSocket text frame. */
export function parseMessage(raw: string): ParseResult {
  let data: unknown;
  try {
    data = JSON.parse(raw);
  } catch {
    return { ok: false, error: "not JSON" };
  }
  return validateMessage(data);
}
