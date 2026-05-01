import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { isTerminalRestoreFailureState, matchesRunningRestoreState, parseS3Bucket } from "./restore-pure";

describe("parseS3Bucket", () => {
  it("extracts bucket from s3:// URL", () => {
    assert.equal(parseS3Bucket("s3://my-bucket/db-2024-01-01-00:00:00-full"), "my-bucket");
    assert.equal(parseS3Bucket("s3://b/prefix/obj"), "b");
  });

  it("throws on invalid destination", () => {
    assert.throws(() => parseS3Bucket("https://example/x"), /Cannot parse S3 bucket/);
    assert.throws(() => parseS3Bucket("nope"), /Cannot parse S3 bucket/);
  });
});

describe("matchesRunningRestoreState", () => {
  it("matches Starting and Running", () => {
    assert.equal(matchesRunningRestoreState("Starting"), true);
    assert.equal(matchesRunningRestoreState("Running"), true);
    assert.equal(matchesRunningRestoreState("Succeeded"), false);
    assert.equal(matchesRunningRestoreState(undefined), false);
  });
});

describe("isTerminalRestoreFailureState", () => {
  it("matches Failed and Error", () => {
    assert.equal(isTerminalRestoreFailureState("Failed"), true);
    assert.equal(isTerminalRestoreFailureState("Error"), true);
    assert.equal(isTerminalRestoreFailureState("Running"), false);
    assert.equal(isTerminalRestoreFailureState(undefined), false);
  });
});
