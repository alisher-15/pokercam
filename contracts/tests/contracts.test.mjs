import assert from "node:assert/strict";
import { existsSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { describe, it } from "node:test";
import { CONTRACTS_DIR, createAjv, messageFiles, modelFiles, readJson, schemaFiles, schemaId } from "../scripts/schemas.mjs";

const ajv = createAjv();
const validate = (rel, data) => {
  const fn = ajv.getSchema(schemaId(rel));
  return { ok: fn(data), errors: ajv.errorsText(fn.errors) };
};

function exampleFiles(dir = join(CONTRACTS_DIR, "examples"), prefix = "") {
  return readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const rel = prefix ? `${prefix}/${entry.name}` : entry.name;
    return entry.isDirectory() ? exampleFiles(join(dir, entry.name), rel) : [rel];
  });
}

/** Calls visit(subschema, path) for the schema and every schema nested in it. */
function walkSchema(schema, visit, path = "#") {
  if (typeof schema !== "object" || schema === null) return;
  visit(schema, path);
  for (const key of ["properties", "definitions"]) {
    for (const [name, sub] of Object.entries(schema[key] ?? {})) walkSchema(sub, visit, `${path}/${key}/${name}`);
  }
  if (schema.items) walkSchema(schema.items, visit, `${path}/items`);
}

describe("schemas", () => {
  it("compile", () => {
    for (const rel of schemaFiles()) assert.ok(ajv.getSchema(schemaId(rel)), rel);
  });

  it("have exactly one example each", () => {
    assert.deepEqual(exampleFiles().sort(), modelFiles().sort());
  });

  it("name a message file after its type", () => {
    for (const rel of messageFiles()) {
      const type = rel.split("/").pop().replace(/\.json$/, "");
      assert.equal(readJson(rel).properties.type.const, type, rel);
    }
  });

  // These rules keep the generated Dart, TypeScript and Python types usable.
  for (const rel of schemaFiles()) {
    it(`follow the codegen rules: ${rel}`, () => {
      walkSchema(readJson(rel), (schema, path) => {
        const where = `${rel} ${path}`;
        if (schema.properties) {
          assert.equal(schema.additionalProperties, false, `${where}: objects with properties must forbid others`);
          assert.ok(schema.title, `${where}: objects with properties need a title (it names the generated class)`);
        }
        if (schema.enum && schema.enum.length > 1) assert.ok(schema.title, `${where}: enums need a title`);
        for (const [name, sub] of Object.entries(schema.properties ?? {})) {
          // quicktype's Dart turns a missing optional array into [], so arrays must always be sent.
          if (sub.type === "array") assert.ok(schema.required?.includes(name), `${where}: array ${name} must be required`);
          assert.notEqual(sub.type?.includes?.("null"), true, `${where}: ${name}: nulls are never sent, leave the field out`);
        }
      });
    });
  }
});

describe("examples", () => {
  for (const rel of modelFiles()) {
    it(`are valid: ${rel}`, () => {
      const { ok, errors } = validate(rel, readJson(`examples/${rel}`));
      assert.ok(ok, errors);
    });
  }

  for (const rel of messageFiles()) {
    it(`fit the envelope: ${rel}`, () => {
      const { ok, errors } = validate("ws/envelope.json", readJson(`examples/${rel}`));
      assert.ok(ok, errors);
    });
  }
});

describe("invalid messages are rejected", () => {
  const base = readJson("examples/ws/control/camera.set.json");
  const cases = {
    "manual mode without a value": ["ws/control/camera.set.json", { ...base, payload: { param: "iso", control: { mode: "manual" } } }],
    "preset mode without a preset": [
      "ws/control/camera.set.json",
      { ...base, payload: { param: "white_balance", control: { mode: "preset" } } },
    ],
    "unknown parameter": ["ws/control/camera.set.json", { ...base, payload: { param: "flash", control: { mode: "auto" } } }],
    "extra field": ["ws/control/camera.set.json", { ...base, extra: 1 }],
    "table_id that is not a UUID": ["ws/control/camera.set.json", { ...base, table_id: "table-1" }],
    "type of another message": ["ws/control/camera.set.json", { ...base, type: "camera.state" }],
    "null instead of a missing field": [
      "ws/control/camera.set.json",
      { ...base, payload: { param: "iso", control: { mode: "auto", value: null } } },
    ],
    "grace without grace_until": [
      "ws/control/license.status.json",
      { ...readJson("examples/ws/control/license.status.json"), payload: { status: "grace" } },
    ],
    "pairing code of 5 digits": ["rest/device_pair_request.json", { ...readJson("examples/rest/device_pair_request.json"), code: "12345" }],
    "envelope with a bad type": ["ws/envelope.json", { ...base, type: "Camera Set" }],
  };
  for (const [name, [rel, data]] of Object.entries(cases)) {
    it(name, () => assert.equal(validate(rel, data).ok, false));
  }
});

describe("brands", () => {
  const brandsDir = join(CONTRACTS_DIR, "..", "branding");
  for (const brand of readdirSync(brandsDir)) {
    it(`branding/${brand}/brand.json is valid and its files exist`, () => {
      const config = readJson(`../branding/${brand}/brand.json`);
      const { ok, errors } = validate("branding/brand_config.json", config);
      assert.ok(ok, errors);
      for (const file of [config.logo, config.icon]) assert.ok(existsSync(join(brandsDir, brand, file)), `${brand}/${file}`);
    });
  }
});
