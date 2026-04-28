export function logLine(message: string): void {
  console.log(`${new Date().toISOString()} ${message}`);
}
