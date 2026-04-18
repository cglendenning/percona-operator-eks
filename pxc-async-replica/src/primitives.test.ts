import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { asString } from "./primitives";

describe("asString", () => {
  it("returns string values", () => {
    assert.equal(asString("x"), "x");
    assert.equal(asString(""), "");
  });

  it("returns empty string for non-strings", () => {
    assert.equal(asString(null), "");
    assert.equal(asString(undefined), "");
    assert.equal(asString(1), "");
    assert.equal(asString({}), "");
  });
});
