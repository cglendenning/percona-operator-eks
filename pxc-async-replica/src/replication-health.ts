import type { SlaveStatus } from "./mysql";

/** Coordinates for how far the replica SQL thread has applied on the source binlog (`Relay_Master_Log_File` + `Exec_Master_Log_Pos`). */
export type AppliedExecCoords = { file: string; pos: number };

/** IO and SQL threads both report `Yes` (MySQL convention). */
export function slaveIoSqlRunning(s: SlaveStatus): boolean {
  return s.ioRunning === "Yes" && s.sqlRunning === "Yes";
}

/** IO thread is `Yes` but the SQL/applier thread is not (stopped, error, connecting, etc.). */
export function ioOkSqlNotRunning(s: SlaveStatus): boolean {
  return s.ioRunning === "Yes" && s.sqlRunning !== "Yes";
}

/** Seconds until `deadlineMs`, floored at zero (for poll-timeout countdowns). */
export function secondsRemainingUntilDeadline(deadlineMs: number, nowMs: number = Date.now()): number {
  return Math.max(0, Math.ceil((deadlineMs - nowMs) / 1000));
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

export function appliedCoordsFromSlave(s: SlaveStatus): AppliedExecCoords | null {
  const file = s.relayMasterLogFile?.trim();
  const pos = s.execMasterLogPos;
  if (!file || pos === null) return null;
  return { file, pos };
}

/** True if `next` is strictly ahead of `prev` on the source binlog (same file: higher pos; new file: lexicographically greater name, typical for `mysql-bin.000047`). */
export function appliedCoordsAdvanced(prev: AppliedExecCoords, next: AppliedExecCoords): boolean {
  if (prev.file === next.file) return next.pos > prev.pos;
  return next.file > prev.file;
}

/**
 * Lag is above the healthy threshold, but IO/SQL threads are up, replication is not broken,
 * and the applied position has moved forward since `previousApplied` — replica is catching up, not stuck.
 */
export function isCatchingUpLag(
  s: SlaveStatus,
  maxLagSeconds: number,
  previousApplied: AppliedExecCoords | null
): boolean {
  if (!previousApplied) return false;
  if (!slaveIoSqlRunning(s)) return false;
  if (replicationBroken(s)) return false;
  if (slaveLooksHealthy(s, maxLagSeconds)) return false;
  const curr = appliedCoordsFromSlave(s);
  if (!curr) return false;
  return appliedCoordsAdvanced(previousApplied, curr);
}

export function formatSlaveStatusLogLine(s: SlaveStatus): string {
  const applied =
    s.relayMasterLogFile && s.execMasterLogPos != null
      ? ` applied=${s.relayMasterLogFile}:${s.execMasterLogPos}`
      : "";
  const ioRead =
    s.sourceLogFile && s.readSourceLogPos != null ? ` ioRead=${s.sourceLogFile}:${s.readSourceLogPos}` : "";
  return (
    `IO=${s.ioRunning} SQL=${s.sqlRunning} lag=${s.secondsBehind ?? "null"}s${applied}${ioRead} ` +
    `ioErr=${JSON.stringify(s.lastIoError)} sqlErr=${JSON.stringify(s.lastSqlError)}`
  );
}

/**
 * True when `Last_SQL_Error` tells the operator to inspect
 * `performance_schema.replication_applier_status_by_worker` for the concrete failure.
 */
export function sqlErrorSuggestsApplierWorkerTable(lastSqlError: string): boolean {
  const t = lastSqlError.trim();
  if (!t) return false;
  return /replication_applier_status_by_worker/i.test(t);
}

/** Heuristic: replica errors indicate the source binlog stream is missing or unreadable (purge, rotation, path). */
export function slaveErrorsSuggestMissingSourceBinlogs(s: SlaveStatus): boolean {
  const t = `${s.lastIoError} ${s.lastSqlError}`;
  return /binlog|binary log|log file|Could not find|could not find|first log file|does not exist|was not found|purged|rotated away|ER_MASTER_FATAL_ERROR_READING_BINLOG|1236|connecting to source|failed to open/i.test(
    t
  );
}
