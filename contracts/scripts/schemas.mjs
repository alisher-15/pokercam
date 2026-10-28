// Finds and loads the contract schemas. Shared by the contract tests and codegen.
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import Ajv from "ajv";
import addFormats from "ajv-formats";

export const CONTRACTS_DIR = fileURLToPath(new URL("..", import.meta.url));

// Directories that hold schemas; common.json at the root holds shared definitions.
const SCHEMA_DIRS = ["ws", "rest", "auth", "branding"];

// Schemas carry no $id on disk (quicktype would try to fetch it); this base only resolves relative $refs.
const BASE_ID = "https://contracts.invalid/";

function walk(dir, prefix) {
  return readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const rel = `${prefix}/${entry.name}`;
    if (entry.isDirectory()) return walk(join(dir, entry.name), rel);
    return entry.name.endsWith(".json") ? [rel] : [];
  });
}

/** Paths of every schema relative to contracts/, common.json first, the rest sorted. */
export function schemaFiles() {
  const files = SCHEMA_DIRS.flatMap((d) => walk(join(CONTRACTS_DIR, d), d)).sort();
  return ["common.json", ...files];
}

/** Paths of every schema that describes a message or model (everything except common.json). */
export function modelFiles() {
  return schemaFiles().filter((rel) => rel !== "common.json");
}

/** Paths of every WebSocket message schema (envelope.json is not a message). */
export function messageFiles() {
  return modelFiles().filter((rel) => rel.startsWith("ws/") && rel !== "ws/envelope.json");
}

export function readJson(rel) {
  return JSON.parse(readFileSync(join(CONTRACTS_DIR, rel), "utf8"));
}

export function schemaId(rel) {
  return BASE_ID + rel;
}

/** An Ajv instance with every schema registered under schemaId(rel). */
export function createAjv() {
  const ajv = new Ajv({ strict: true, strictRequired: false, allErrors: true });
  addFormats(ajv);
  for (const rel of schemaFiles()) ajv.addSchema({ ...readJson(rel), $id: schemaId(rel) });
  return ajv;
}
