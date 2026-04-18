import { sleep } from "./log";

export async function waitUntilTrue(args: {
  pollMs: number;
  deadlineMs: number;
  isShuttingDown: () => boolean;
  predicate: () => Promise<boolean>;
}): Promise<boolean> {
  const deadline = Date.now() + args.deadlineMs;
  while (!args.isShuttingDown() && Date.now() < deadline) {
    if (await args.predicate()) return true;
    await sleep(args.pollMs);
  }
  return false;
}
