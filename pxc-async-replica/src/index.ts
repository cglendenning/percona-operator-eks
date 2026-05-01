import { formatK8sError } from "./k8s-errors";
import { log, sleep } from "./log";
import { isDefinitelyFatalError } from "./transient-errors";
import { runController } from "./controller";

let outerStopping = false;
function onOuterStop() {
  outerStopping = true;
}
process.on("SIGTERM", onOuterStop);
process.on("SIGINT", onOuterStop);

async function main(): Promise<void> {
  let recoverableAttempt = 0;
  while (!outerStopping) {
    try {
      await runController();
      return;
    } catch (e: unknown) {
      if (outerStopping) return;
      if (isDefinitelyFatalError(e)) {
        log(`FATAL (fix configuration or RBAC; retrying will not help): ${formatK8sError(e)}`);
        process.exit(1);
      }
      recoverableAttempt += 1;
      const errText = formatK8sError(e);
      const baseDelay = Math.min(60_000, Math.round(2000 * Math.pow(1.35, Math.min(recoverableAttempt, 14))));
      /** Restore failures must not use the short outer backoff (they bypass in-loop re-seed cooldown if thrown unexpectedly). */
      const delay = /Restore did not succeed/i.test(errText) ? Math.max(baseDelay, 300_000) : baseDelay;
      log(
        `Recoverable error; restarting controller after backoff (attempt ${recoverableAttempt}, sleep ${delay}ms): ${errText}`
      );
      const step = 500;
      let waited = 0;
      while (!outerStopping && waited < delay) {
        await sleep(Math.min(step, delay - waited));
        waited += step;
      }
    }
  }
}

main().catch((e: unknown) => {
  log(`FATAL: ${formatK8sError(e)}`);
  process.exit(1);
});
