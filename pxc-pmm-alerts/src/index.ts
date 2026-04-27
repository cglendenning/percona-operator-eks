import { runController } from "./controller";

runController()
  .then(() => {
    console.log("pxc-pmm-alerts-controller completed successfully");
    process.exit(0);
  })
  .catch((err: unknown) => {
    const message = err instanceof Error ? err.message : String(err);
    console.error(`pxc-pmm-alerts-controller failed: ${message}`);
    process.exit(1);
  });
