import assert from "node:assert/strict";
import { describe, it } from "node:test";
import type { SlaveStatus } from "./mysql";
import {
  formatSlaveStatusLogLine,
  replicationBroken,
  slaveIoSqlRunning,
  slaveLooksHealthy,
} from "./replication-health";

function s(partial: Partial<SlaveStatus>): SlaveStatus {
  return {
    ioRunning: partial.ioRunning ?? "No",
    sqlRunning: partial.sqlRunning ?? "No",
    secondsBehind: partial.secondsBehind ?? null,
    lastIoError: partial.lastIoError ?? "",
    lastSqlError: partial.lastSqlError ?? "",
    lastErrno: partial.lastErrno ?? null,
  };
}

describe("slaveIoSqlRunning", () => {
  it("is true only when both threads are Yes", () => {
    assert.equal(slaveIoSqlRunning(s({ ioRunning: "Yes", sqlRunning: "Yes" })), true);
    assert.equal(slaveIoSqlRunning(s({ ioRunning: "Yes", sqlRunning: "Connecting" })), false);
    assert.equal(slaveIoSqlRunning(s({ ioRunning: "No", sqlRunning: "Yes" })), false);
  });
});

describe("slaveLooksHealthy", () => {
  it("requires running threads, non-null lag, and lag within bound", () => {
    assert.equal(slaveLooksHealthy(s({ ioRunning: "Yes", sqlRunning: "Yes", secondsBehind: 0 }), 5), true);
    assert.equal(slaveLooksHealthy(s({ ioRunning: "Yes", sqlRunning: "Yes", secondsBehind: 5 }), 5), true);
    assert.equal(slaveLooksHealthy(s({ ioRunning: "Yes", sqlRunning: "Yes", secondsBehind: 6 }), 5), false);
    assert.equal(slaveLooksHealthy(s({ ioRunning: "Yes", sqlRunning: "Yes", secondsBehind: null }), 5), false);
    assert.equal(slaveLooksHealthy(s({ ioRunning: "Yes", sqlRunning: "No", secondsBehind: 0 }), 5), false);
  });
});

describe("replicationBroken", () => {
  it("treats null as broken", () => {
    assert.equal(replicationBroken(null), true);
  });

  it("treats non-Yes threads as broken", () => {
    assert.equal(replicationBroken(s({ ioRunning: "Connecting", sqlRunning: "Yes" })), true);
  });

  it("treats non-empty last IO/SQL errors as broken even when threads Yes", () => {
    assert.equal(replicationBroken(s({ ioRunning: "Yes", sqlRunning: "Yes", lastIoError: "oops" })), true);
    assert.equal(replicationBroken(s({ ioRunning: "Yes", sqlRunning: "Yes", lastSqlError: "boom" })), true);
  });

  it("is false when threads Yes and errors empty", () => {
    assert.equal(replicationBroken(s({ ioRunning: "Yes", sqlRunning: "Yes", secondsBehind: 0 })), false);
  });
});

describe("formatSlaveStatusLogLine", () => {
  it("includes IO, SQL, lag, and JSON-escaped errors", () => {
    const line = formatSlaveStatusLogLine(
      s({
        ioRunning: "Yes",
        sqlRunning: "Yes",
        secondsBehind: 3,
        lastIoError: "tls timeout",
        lastSqlError: "",
      })
    );
    assert.match(line, /IO=Yes/);
    assert.match(line, /SQL=Yes/);
    assert.match(line, /lag=3s/);
    assert.match(line, /ioErr="tls timeout"/);
  });

  it("renders null lag as the string null", () => {
    const line = formatSlaveStatusLogLine(s({ ioRunning: "Yes", sqlRunning: "Yes", secondsBehind: null }));
    assert.match(line, /lag=nulls/);
  });
});
