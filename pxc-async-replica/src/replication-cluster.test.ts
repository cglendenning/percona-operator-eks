import assert from "node:assert/strict";
import { describe, it } from "node:test";
import type { Obj } from "./types";
import { isPxcClusterReadyBody } from "./replication";

describe("isPxcClusterReadyBody", () => {
  it("returns false for null", () => {
    assert.equal(isPxcClusterReadyBody(null), false);
  });

  it("returns false when state is not ready", () => {
    const body = { status: { state: "initializing" } } as Obj;
    assert.equal(isPxcClusterReadyBody(body), false);
  });

  it("returns true when state is ready", () => {
    const body = { status: { state: "ready" } } as Obj;
    assert.equal(isPxcClusterReadyBody(body), true);
  });

  it("returns false when status missing", () => {
    assert.equal(isPxcClusterReadyBody({} as Obj), false);
  });
});
