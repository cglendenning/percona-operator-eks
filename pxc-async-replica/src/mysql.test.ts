import assert from "node:assert/strict";
import { describe, it } from "node:test";
import {
  buildShowReplicaStatusForChannelSql,
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
