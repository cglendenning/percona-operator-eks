import type { SlaveStatus } from "./mysql";

/** IO and SQL threads both report `Yes` (MySQL convention). */
export function slaveIoSqlRunning(s: SlaveStatus): boolean {
  return s.ioRunning === "Yes" && s.sqlRunning === "Yes";
}

export function slaveLooksHealthy(s: SlaveStatus, maxLagSeconds: number): boolean {
  if (!slaveIoSqlRunning(s)) return false;
  if (s.secondsBehind === null) return false;
  return s.secondsBehind <= maxLagSeconds;
}

export function replicationBroken(s: SlaveStatus | null): boolean {
  if (!s) return true;
  if (!slaveIoSqlRunning(s)) return true;
  if (s.lastIoError || s.lastSqlError) return true;
  return false;
}

export function formatSlaveStatusLogLine(s: SlaveStatus): string {
  return (
    `IO=${s.ioRunning} SQL=${s.sqlRunning} lag=${s.secondsBehind ?? "null"}s ` +
    `ioErr=${JSON.stringify(s.lastIoError)} sqlErr=${JSON.stringify(s.lastSqlError)}`
  );
}
