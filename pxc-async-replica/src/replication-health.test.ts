import assert from "node:assert/strict";
import { describe, it } from "node:test";
import type { SlaveStatus } from "./mysql";
import {
  appliedCoordsAdvanced,
  formatSlaveStatusLogLine,
  ioOkSqlNotRunning,
  isCatchingUpLag,
  replicationBroken,
  secondsRemainingUntilDeadline,
  slaveErrorsSuggestMissingSourceBinlogs,
  slaveIoSqlRunning,
  slaveLooksHealthy,
  sqlErrorSuggestsApplierWorkerTable,
} from "./replication-health";

function s(partial: Partial<SlaveStatus>): SlaveStatus {
  return {
    ioRunning: partial.ioRunning ?? "No",
    sqlRunning: partial.sqlRunning ?? "No",
    secondsBehind: partial.secondsBehind ?? null,
    relayMasterLogFile: partial.relayMasterLogFile ?? "",
    execMasterLogPos: partial.execMasterLogPos ?? null,
    sourceLogFile: partial.sourceLogFile ?? "",
    readSourceLogPos: partial.readSourceLogPos ?? null,
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

describe("ioOkSqlNotRunning", () => {
  it("is true only when IO Yes and SQL not Yes", () => {
    assert.equal(ioOkSqlNotRunning(s({ ioRunning: "Yes", sqlRunning: "No" })), true);
    assert.equal(ioOkSqlNotRunning(s({ ioRunning: "Yes", sqlRunning: "Connecting" })), true);
    assert.equal(ioOkSqlNotRunning(s({ ioRunning: "Yes", sqlRunning: "Yes" })), false);
    assert.equal(ioOkSqlNotRunning(s({ ioRunning: "No", sqlRunning: "No" })), false);
  });
});

describe("secondsRemainingUntilDeadline", () => {
  it("floors at zero and rounds up to whole seconds", () => {
    assert.equal(secondsRemainingUntilDeadline(10_500, 8000), 3);
    assert.equal(secondsRemainingUntilDeadline(8000, 8000), 0);
    assert.equal(secondsRemainingUntilDeadline(7000, 8000), 0);
  });
});

describe("sqlErrorSuggestsApplierWorkerTable", () => {
  it("is true when Last_SQL_Error references replication_applier_status_by_worker", () => {
    assert.equal(
      sqlErrorSuggestsApplierWorkerTable(
        "Coordinator stopped because there were error(s) in the worker(s). See error log and/or performance_schema.replication_applier_status_by_worker table for more details."
      ),
      true
    );
  });

  it("is false for empty or unrelated messages", () => {
    assert.equal(sqlErrorSuggestsApplierWorkerTable(""), false);
    assert.equal(sqlErrorSuggestsApplierWorkerTable("duplicate key"), false);
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

describe("appliedCoordsAdvanced", () => {
  it("detects forward progress on the same file", () => {
    assert.equal(
      appliedCoordsAdvanced({ file: "mysql-bin.000001", pos: 100 }, { file: "mysql-bin.000001", pos: 200 }),
      true
    );
    assert.equal(
      appliedCoordsAdvanced({ file: "mysql-bin.000001", pos: 100 }, { file: "mysql-bin.000001", pos: 100 }),
      false
    );
  });

  it("detects forward progress after binlog rotation", () => {
    assert.equal(
      appliedCoordsAdvanced({ file: "mysql-bin.000009", pos: 9999 }, { file: "mysql-bin.000010", pos: 4 }),
      true
    );
  });
});

describe("isCatchingUpLag", () => {
  const prev = { file: "mysql-bin.000001", pos: 100 };
  const maxLag = 5;

  it("is false without a previous sample", () => {
    assert.equal(
      isCatchingUpLag(
        s({
          ioRunning: "Yes",
          sqlRunning: "Yes",
          secondsBehind: 99,
          relayMasterLogFile: "mysql-bin.000001",
          execMasterLogPos: 200,
        }),
        maxLag,
        null
      ),
      false
    );
  });

  it("is true when lag is high, threads are up, not broken, and apply position advanced", () => {
    assert.equal(
      isCatchingUpLag(
        s({
          ioRunning: "Yes",
          sqlRunning: "Yes",
          secondsBehind: 99,
          relayMasterLogFile: "mysql-bin.000001",
          execMasterLogPos: 200,
        }),
        maxLag,
        prev
      ),
      true
    );
  });

  it("is false when apply position did not advance", () => {
    assert.equal(
      isCatchingUpLag(
        s({
          ioRunning: "Yes",
          sqlRunning: "Yes",
          secondsBehind: 99,
          relayMasterLogFile: "mysql-bin.000001",
          execMasterLogPos: 100,
        }),
        maxLag,
        prev
      ),
      false
    );
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

  it("includes applied coordinates when present", () => {
    const line = formatSlaveStatusLogLine(
      s({
        ioRunning: "Yes",
        sqlRunning: "Yes",
        secondsBehind: 12,
        relayMasterLogFile: "mysql-bin.000003",
        execMasterLogPos: 444,
      })
    );
    assert.match(line, /applied=mysql-bin\.000003:444/);
  });

  it("renders null lag as the string null", () => {
    const line = formatSlaveStatusLogLine(s({ ioRunning: "Yes", sqlRunning: "Yes", secondsBehind: null }));
    assert.match(line, /lag=nulls/);
  });

  it("includes IO read coordinates when present", () => {
    const line = formatSlaveStatusLogLine(
      s({
        ioRunning: "Connecting",
        sqlRunning: "Yes",
        secondsBehind: null,
        relayMasterLogFile: "mysql-bin.000010",
        execMasterLogPos: 99,
        sourceLogFile: "mysql-bin.000011",
        readSourceLogPos: 4,
      })
    );
    assert.match(line, /ioRead=mysql-bin\.000011:4/);
  });
});

describe("slaveErrorsSuggestMissingSourceBinlogs", () => {
  it("is true for common binlog / purge wording", () => {
    assert.equal(
      slaveErrorsSuggestMissingSourceBinlogs(
        s({ lastIoError: "binlog file mysql-bin.000042 not found", lastSqlError: "" })
      ),
      true
    );
    assert.equal(slaveErrorsSuggestMissingSourceBinlogs(s({ lastIoError: "", lastSqlError: "Error 1236" })), true);
  });

  it("is false for unrelated errors", () => {
    assert.equal(slaveErrorsSuggestMissingSourceBinlogs(s({ lastIoError: "Access denied", lastSqlError: "" })), false);
  });
});
