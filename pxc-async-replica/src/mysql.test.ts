import assert from "node:assert/strict";
import { describe, it } from "node:test";
import type { Pool } from "mysql2/promise";
import {
  applyMysqlHostPortToBaseUrl,
  buildShowReplicaStatusForChannelSql,
  fetchReplicationApplierStatusByWorker,
  mergePasswordIntoMysqlUrl,
  mergeUserAndPasswordIntoMysqlUrl,
} from "./mysql";

describe("buildShowReplicaStatusForChannelSql", () => {
  it("builds SHOW REPLICA STATUS FOR CHANNEL with quoted name", () => {
    assert.equal(
      buildShowReplicaStatusForChannelSql("wookie_primary_to_replica"),
      "SHOW REPLICA STATUS FOR CHANNEL 'wookie_primary_to_replica'"
    );
  });

  it("escapes single quotes in channel name", () => {
    assert.equal(buildShowReplicaStatusForChannelSql("ch'1"), "SHOW REPLICA STATUS FOR CHANNEL 'ch''1'");
  });

  it("rejects empty channel after trim", () => {
    assert.throws(() => buildShowReplicaStatusForChannelSql("   "), /non-empty/);
  });
});

describe("mergeUserAndPasswordIntoMysqlUrl", () => {
  it("sets user and password regardless of URL placeholder user", () => {
    const out = mergeUserAndPasswordIntoMysqlUrl(
      "mysql://root@h.example:3307/dbname",
      "replication",
      "s3cret"
    );
    const u = new URL(out);
    assert.equal(u.username, "replication");
    assert.equal(u.password, "s3cret");
    assert.equal(u.hostname, "h.example");
    assert.equal(u.port, "3307");
    assert.equal(u.pathname, "/dbname");
  });

  it("rejects empty user", () => {
    assert.throws(() => mergeUserAndPasswordIntoMysqlUrl("mysql://x@h/db", "", "p"), /user must be non-empty/);
  });
});

describe("mergePasswordIntoMysqlUrl", () => {
  it("injects password into mysql:// URL", () => {
    const out = mergePasswordIntoMysqlUrl("mysql://root@haproxy.example:3306/mysql", "secret");
    const u = new URL(out);
    assert.equal(u.protocol, "mysql:");
    assert.equal(u.username, "root");
    assert.equal(u.password, "secret");
    assert.equal(u.hostname, "haproxy.example");
    assert.equal(u.port, "3306");
    assert.equal(u.pathname, "/mysql");
  });

  it("accepts mysql2:// protocol", () => {
    const out = mergePasswordIntoMysqlUrl("mysql2://u@host/db", "p");
    assert.equal(new URL(out).protocol, "mysql2:");
    assert.equal(new URL(out).password, "p");
  });

  it("rejects empty password", () => {
    assert.throws(() => mergePasswordIntoMysqlUrl("mysql://root@h/db", ""), /non-empty/);
  });

  it("rejects invalid URL", () => {
    assert.throws(() => mergePasswordIntoMysqlUrl("not-a-url", "x"), /MySQL URL is not a valid URL/);
  });

  it("rejects non-mysql protocols", () => {
    assert.throws(() => mergePasswordIntoMysqlUrl("https://x/", "p"), /mysql:\/\/ or mysql2:\/\//);
  });
});

describe("applyMysqlHostPortToBaseUrl", () => {
  it("replaces host and port", () => {
    const out = applyMysqlHostPortToBaseUrl("mysql://root:pw@oldhost:1111/mysql", "newhost", 3308);
    const u = new URL(out);
    assert.equal(u.hostname, "newhost");
    assert.equal(u.port, "3308");
    assert.equal(u.username, "root");
    assert.equal(u.password, "pw");
    assert.equal(u.pathname, "/mysql");
  });

  it("rejects invalid port", () => {
    assert.throws(() => applyMysqlHostPortToBaseUrl("mysql://u@h/db", "x", 0), /1-65535/);
  });
});

describe("fetchReplicationApplierStatusByWorker", () => {
  it("returns rows on success", async () => {
    const pool = {
      async query() {
        return [[{ CHANNEL_NAME: "ch", THREAD_ID: 42, LAST_ERROR_MESSAGE: "dup key" }], []];
      },
    } as unknown as Pool;
    const r = await fetchReplicationApplierStatusByWorker(pool);
    assert.equal(r.ok, true);
    if (r.ok) assert.equal(r.rows.length, 1);
  });

  it("returns error message on query failure", async () => {
    const pool = {
      async query() {
        throw new Error("denied");
      },
    } as unknown as Pool;
    const r = await fetchReplicationApplierStatusByWorker(pool);
    assert.equal(r.ok, false);
    if (!r.ok) assert.match(r.message, /denied/);
  });
});
