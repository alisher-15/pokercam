// node --test brand/brand.test.ts
import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { brandHeader, cString, defines, loadBrand } from "./brand.ts";

void describe("brands in branding/", () => {
  for (const name of ["default", "demo"]) {
    void it(`${name} loads and flattens into the defines the apps read`, () => {
      const { config } = loadBrand(name);
      const flat = defines(name, config);
      assert.equal(flat.BRAND_ID, name);
      assert.equal(flat.BRAND_APP_NAME, config.app_name);
      assert.equal(flat.BRAND_ANDROID_APPLICATION_ID, config.android_application_id);
      assert.match(flat.BRAND_COLOR_PRIMARY ?? "", /^#[0-9A-Fa-f]{6}$/);
      for (const value of Object.values(flat)) assert.equal(typeof value, "string");
    });
  }

  void it("the two brands differ where a store or Windows tells apps apart", () => {
    const a = loadBrand("default").config;
    const b = loadBrand("demo").config;
    assert.notEqual(a.android_application_id, b.android_application_id);
    assert.notEqual(a.windows_app_id, b.windows_app_id);
    assert.notEqual(a.app_name, b.app_name);
  });

  void it("seller contacts go along as JSON, only when the brand has them", () => {
    const { config } = loadBrand("demo");
    assert.deepEqual(JSON.parse(defines("demo", config).BRAND_SELLER_CONTACTS ?? "{}"), config.seller_contacts);
    assert.equal(defines("x", { ...config, seller_contacts: undefined }).BRAND_SELLER_CONTACTS, undefined);
  });

  void it("an unknown or odd name is refused", () => {
    assert.throws(() => loadBrand("nope"), /no .*brand\.json/);
    assert.throws(() => loadBrand("../backend"), /bad brand name/);
  });
});

void describe("C strings for Runner.rc and main.cpp", () => {
  void it("ASCII as it is, quotes and backslashes escaped", () => {
    assert.equal(cString('Table "1"\\'), '"Table \\"1\\"\\\\"');
  });

  void it("non-ASCII as UTF-8 bytes, the literal split where a hex digit follows", () => {
    // "Стол A": С = d0 a1, т = d1 82, о = d0 be, л = d0 bb; the space after л is not a hex digit, "A" is.
    assert.equal(cString("Стол A"), '"\\xd0\\xa1\\xd1\\x82\\xd0\\xbe\\xd0\\xbb A"');
    assert.equal(cString("ЖA"), '"\\xd0\\x96""A"');
  });

  void it("wide strings as \\u escapes", () => {
    assert.equal(cString("Стол", true), 'L"\\u0421\\u0442\\u043e\\u043b"');
  });

  void it("the header defines both names", () => {
    const header = brandHeader(loadBrand("demo").config);
    assert.match(header, /#define BRAND_APP_NAME "TableGuard"/);
    assert.match(header, /#define BRAND_WINDOW_TITLE L"TableGuard"/);
  });
});
