import test from "node:test";
import assert from "node:assert/strict";
import {
  isDefinitelyFatalError,
  isRecoverableInfrastructureError,
  isTransientNetworkError,
  retryWithBackoff,
} from "./transient-errors";

test("isTransientNetworkError: EAI_AGAIN message", () => {
  assert.equal(isTransientNetworkError(new Error("getaddrinfo EAI_AGAIN kubernetes.default.svc")), true);
});

test("isTransientNetworkError: errno code", () => {
  const e = new Error("fail") as NodeJS.ErrnoException;
  e.code = "EAI_AGAIN";
  assert.equal(isTransientNetworkError(e), true);
});

test("isTransientNetworkError: follows error.cause", () => {
  const inner = new Error("getaddrinfo EAI_AGAIN");
  const outer = new Error("HTTP request failed") as Error & { cause?: unknown };
  outer.cause = inner;
  assert.equal(isTransientNetworkError(outer), true);
});

test("isTransientNetworkError: 503 statusCode", () => {
  assert.equal(isTransientNetworkError({ statusCode: 503, message: "x" }), true);
});

test("isTransientNetworkError: non-retryable 400", () => {
  assert.equal(isTransientNetworkError({ statusCode: 400, message: "x" }), false);
});

test("isDefinitelyFatalError: missing env", () => {
  assert.equal(isDefinitelyFatalError(new Error("Missing required env var: FOO")), true);
});

test("isDefinitelyFatalError: 403", () => {
  assert.equal(isDefinitelyFatalError({ statusCode: 403, message: "Forbidden" }), true);
});

test("isDefinitelyFatalError: 401", () => {
  assert.equal(isDefinitelyFatalError({ statusCode: 401, message: "Unauthorized" }), true);
});

test("isDefinitelyFatalError: secret shape", () => {
  assert.equal(isDefinitelyFatalError(new Error("Secret missing data key: replication")), true);
});

test("isDefinitelyFatalError: unknown runtime error is not fatal", () => {
  assert.equal(isDefinitelyFatalError(new Error("S3 list bucket timeout")), false);
});

test("isRecoverableInfrastructureError: 404 and 500", () => {
  assert.equal(isRecoverableInfrastructureError({ statusCode: 404 }), true);
  assert.equal(isRecoverableInfrastructureError({ statusCode: 500 }), true);
});

test("isRecoverableInfrastructureError: 403 is not recoverable", () => {
  assert.equal(isRecoverableInfrastructureError({ statusCode: 403 }), false);
});

test("isRecoverableInfrastructureError: generic error defaults recoverable", () => {
  assert.equal(isRecoverableInfrastructureError(new Error("patch failed: admission webhook denied")), true);
});

test("isRecoverableInfrastructureError: MySQL errno 2013", () => {
  assert.equal(isRecoverableInfrastructureError({ message: "x", errno: 2013 }), true);
});

test("retryWithBackoff: succeeds after failures", async () => {
  let n = 0;
  const v = await retryWithBackoff({
    label: "t",
    fn: async () => {
      n += 1;
      if (n < 3) throw Object.assign(new Error("getaddrinfo EAI_AGAIN"), { code: "EAI_AGAIN" });
      return 42;
    },
    maxAttempts: 10,
    baseDelayMs: 1,
    maxDelayMs: 10,
  });
  assert.equal(v, 42);
  assert.equal(n, 3);
});
