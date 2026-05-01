import assert from "node:assert/strict";
import { describe, it } from "node:test";
import type { Obj } from "./channel-normalize";
import {
  buildDesiredChannels,
  channelsMatchSpec,
  extractReplicationSourcesFromPxcBody,
  normalizeChannels,
  pickPreferredReplicationSource,
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

  it("includes replication channel configuration for operator source retries", () => {
    const desired = buildDesiredChannels(
      "c1",
      [{ host: "h1", port: 3306, weight: 100 }],
      { sourceRetryCount: 100_000, sourceConnectRetry: 10 }
    );
    const fromCluster = [
      {
        name: "c1",
        isSource: false,
        configuration: { sourceConnectRetry: 10, sourceRetryCount: 100_000 },
        sourcesList: [{ host: "h1", port: 3306, weight: 100 }],
      },
    ];
    assert.equal(channelsMatchSpec(fromCluster, desired), true);
  });
});

describe("extractReplicationSourcesFromPxcBody", () => {
  it("returns sources for the named channel", () => {
    const body = {
      spec: {
        pxc: {
          replicationChannels: [
            {
              name: "ch-a",
              sourcesList: [{ host: "old.svc", port: 3306, weight: 100 }],
            },
            {
              name: "ch-b",
              sourcesList: [
                { host: "b1", port: "3307", weight: 50 },
                { host: "b0", weight: 200 },
              ],
            },
          ],
        },
      },
    };
    const s = extractReplicationSourcesFromPxcBody(body, "ch-b", 3306);
    assert.deepEqual(s, [
      { host: "b1", port: 3307, weight: 50 },
      { host: "b0", port: 3306, weight: 200 },
    ]);
  });

  it("returns null when channel or sources are missing", () => {
    assert.equal(extractReplicationSourcesFromPxcBody(null, "c", 3306), null);
    assert.equal(extractReplicationSourcesFromPxcBody({}, "c", 3306), null);
    assert.equal(
      extractReplicationSourcesFromPxcBody(
        { spec: { pxc: { replicationChannels: [{ name: "x", sourcesList: [] }] } } },
        "x",
        3306
      ),
      null
    );
  });
});

describe("pickPreferredReplicationSource", () => {
  it("prefers higher weight then host name", () => {
    assert.deepEqual(
      pickPreferredReplicationSource([
        { host: "z", port: 3306, weight: 100 },
        { host: "a", port: 3306, weight: 200 },
        { host: "m", port: 3306, weight: 200 },
      ]),
      { host: "a", port: 3306, weight: 200 }
    );
  });
});
