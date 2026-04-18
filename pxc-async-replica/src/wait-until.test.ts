import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { waitUntilTrue } from "./wait-until";

describe("waitUntilTrue", () => {
  it("returns true immediately when predicate is true", async () => {
    let calls = 0;
    const ok = await waitUntilTrue({
      pollMs: 5,
      deadlineMs: 1000,
      isShuttingDown: () => false,
      predicate: async () => {
        calls += 1;
        return true;
      },
    });
    assert.equal(ok, true);
    assert.equal(calls, 1);
  });

  it("returns true after predicate becomes true", async () => {
    let n = 0;
    const ok = await waitUntilTrue({
      pollMs: 2,
      deadlineMs: 500,
      isShuttingDown: () => false,
      predicate: async () => {
        n += 1;
        return n >= 3;
      },
    });
    assert.equal(ok, true);
    assert.ok(n >= 3);
  });

  it("returns false when deadline passes", async () => {
    const ok = await waitUntilTrue({
      pollMs: 5,
      deadlineMs: 25,
      isShuttingDown: () => false,
      predicate: async () => false,
    });
    assert.equal(ok, false);
  });

  it("returns false when shutting down before success", async () => {
    let down = false;
    const ok = await waitUntilTrue({
      pollMs: 5,
      deadlineMs: 500,
      isShuttingDown: () => down,
      predicate: async () => {
        down = true;
        return false;
      },
    });
    assert.equal(ok, false);
  });
});
