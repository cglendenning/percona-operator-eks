import { formatK8sError } from "./k8s-errors";
import { log } from "./log";
import { runController } from "./controller";

runController().catch((e: unknown) => {
  log(`FATAL: ${formatK8sError(e)}`);
  process.exit(1);
});
