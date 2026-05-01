import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { parseBackupWallTimeUtcMsFromFolderPrefix } from "./s3-latest-backup";

describe("parseBackupWallTimeUtcMsFromFolderPrefix", () => {
  it("parses folder timestamp as UTC from name", () => {
    const ms = parseBackupWallTimeUtcMsFromFolderPrefix("db-2024-06-01-12:30:45-full/");
    assert.equal(ms, Date.UTC(2024, 5, 1, 12, 30, 45));
  });

  it("returns null for invalid prefix", () => {
    assert.equal(parseBackupWallTimeUtcMsFromFolderPrefix("not-a-backup/"), null);
  });
});
