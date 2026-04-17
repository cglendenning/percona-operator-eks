export function isoNow(): string {
  return new Date().toISOString();
}

export function log(msg: string): void {
  process.stdout.write(`[${isoNow()}] ${msg}\n`);
}

export function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}
