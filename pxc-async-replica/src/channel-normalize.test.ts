import assert from "node:assert/strict";
import { describe, it } from "node:test";
import type { Obj } from "./channel-normalize";
import {
  buildDesiredChannels,
  channelsMatchSpec,
  normalizeChannels,
  sortKeysDeep,
} from "./channel-normalize";

describe("sortKeysDeep", () => {
  it("orders object keys recursively", () => {
    assert.deepEqual(
      sortKeysDeep({ z: 1, a: { y: 2, x: 3 } }),
      { a: { x: 3, y: 2 }, z: 1 }
    );
  });

  it("maps arrays", () => {
    assert.deepEqual(sortKeysDeep([{ b: 1, a: 2 }]), [{ a: 2, b: 1 }]);
  });
});

describe("normalizeChannels", () => {
  it("matches when only key order differs in sourcesList entries", () => {
    const fromApi = [
      {
        name: "ch1",
        isSource: false,
        sourcesList: [
          { host: "b.example", port: 3306, weight: 100 },
          { weight: 100, port: 3306, host: "a.example" },
        ],
      },
    ];
    const fromPatch = [
      {
        isSource: false,
        name: "ch1",
        sourcesList: [
          { host: "a.example", port: 3306, weight: 100 },
          { host: "b.example", port: 3306, weight: 100 },
        ],
      },
    ];
    assert.equal(normalizeChannels(fromApi), normalizeChannels(fromPatch));
    assert.equal(channelsMatchSpec(fromApi, fromPatch as Obj[]), true);
  });

  it("matches desired spec from buildDesiredChannels after reordering", () => {
    const desired = buildDesiredChannels("c1", [
      { host: "h1", port: 3306, weight: 100 },
      { host: "h2", port: 3306, weight: 100 },
    ]);
    const reordered = [
      {
        name: "c1",
        isSource: false,
        sourcesList: [
          { port: 3306, host: "h2", weight: 100 },
          { host: "h1", weight: 100, port: 3306 },
        ],
      },
    ];
    assert.equal(channelsMatchSpec(reordered, desired), true);
  });
});
