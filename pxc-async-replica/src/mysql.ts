import { createPool, type Pool } from "mysql2/promise";
import { asString } from "./primitives";

export type SlaveStatus = {
  ioRunning: string;
  sqlRunning: string;
  secondsBehind: number | null;
  /**
   * Source binlog file the SQL thread has applied through (`Relay_Master_Log_File` or MySQL 8.4+ `Relay_Source_Log_File`).
   */
  relayMasterLogFile: string;
  /**
   * Position within `relayMasterLogFile` (`Exec_Master_Log_Pos` or MySQL 8.4+ `Exec_Source_Log_Pos`).
   */
  execMasterLogPos: number | null;
  /**
   * Binlog file the IO thread is (or was) reading from the source (`Source_Log_File` / `Master_Log_File`).
   */
  sourceLogFile: string;
  /**
   * Position in `sourceLogFile` for the IO thread (`Read_Source_Log_Pos` / `Read_Master_Log_Pos`).
   */
  readSourceLogPos: number | null;
  lastIoError: string;
  lastSqlError: string;
  lastErrno: number | null;
};

function asNumberOrNull(x: unknown): number | null {
  if (x === null || x === undefined) return null;
  if (typeof x === "number") return Number.isFinite(x) ? x : null;
  if (typeof x === "string") {
    if (x.trim() === "") return null;
    const n = Number(x);
    return Number.isFinite(n) ? n : null;
  }
  return null;
}

export function createMysqlPoolFromEnv(): Pool {
  const url = process.env.MYSQL_URL?.trim();
  if (url) {
    return createPool(url);
  }

  const host = process.env.MYSQL_HOST?.trim();
  const user = process.env.MYSQL_USER?.trim();
  const password = process.env.MYSQL_PASSWORD?.trim();
  const database = process.env.MYSQL_DATABASE?.trim() || "mysql";
  const port = Number(process.env.MYSQL_PORT || "3306");

  if (!host) throw new Error("MYSQL_URL or MYSQL_HOST must be set");
  if (!user) throw new Error("MYSQL_USER must be set when MYSQL_URL is not used");
  if (!password) throw new Error("MYSQL_PASSWORD must be set when MYSQL_URL is not used");

  return createPool({
    host,
    port: Number.isFinite(port) ? port : 3306,
    user,
    password,
    database,
    multipleStatements: false,
  });
}

export function createMysqlPoolFromUrl(url: string): Pool {
  return createPool(url);
}

/**
 * Sets (or replaces) the password on a mysql/mysql2 URL. The URL must not be logged after this call.
 */
export function mergePasswordIntoMysqlUrl(urlStr: string, password: string): string {
  if (!password) throw new Error("MySQL password must be non-empty");
  let u: URL;
  try {
    u = new URL(urlStr);
  } catch {
    throw new Error(`MySQL URL is not a valid URL`);
  }
  if (u.protocol !== "mysql:" && u.protocol !== "mysql2:") {
    throw new Error(`MySQL URL must use mysql:// or mysql2:// (got ${JSON.stringify(u.protocol)})`);
  }
  u.password = password;
  return u.toString();
}

/**
 * Sets username and password on a mysql/mysql2 URL (host/port/database unchanged). Do not log the result.
 */
export function mergeUserAndPasswordIntoMysqlUrl(urlStr: string, user: string, password: string): string {
  if (!user) throw new Error("MySQL user must be non-empty");
  if (!password) throw new Error("MySQL password must be non-empty");
  let u: URL;
  try {
    u = new URL(urlStr);
  } catch {
    throw new Error(`MySQL URL is not a valid URL`);
  }
  if (u.protocol !== "mysql:" && u.protocol !== "mysql2:") {
    throw new Error(`MySQL URL must use mysql:// or mysql2:// (got ${JSON.stringify(u.protocol)})`);
  }
  u.username = user;
  u.password = password;
  return u.toString();
}

/** Replaces hostname and port on a mysql/mysql2 URL; user/password/path unchanged. */
export function applyMysqlHostPortToBaseUrl(baseUrlStr: string, host: string, port: number): string {
  const h = host.trim();
  if (!h) throw new Error("MySQL host must be non-empty");
  if (!Number.isFinite(port) || port <= 0 || port > 65535) {
    throw new Error(`MySQL port must be 1-65535 (got ${JSON.stringify(port)})`);
  }
  let u: URL;
  try {
    u = new URL(baseUrlStr);
  } catch {
    throw new Error(`MySQL URL is not a valid URL`);
  }
  if (u.protocol !== "mysql:" && u.protocol !== "mysql2:") {
    throw new Error(`MySQL URL must use mysql:// or mysql2:// (got ${JSON.stringify(u.protocol)})`);
  }
  u.hostname = h;
  u.port = String(port);
  return u.toString();
}

function sqlStringLiteral(s: string): string {
  return `'${s.replace(/'/g, "''")}'`;
}

/**
 * SQL for `SHOW REPLICA STATUS` scoped to a named replication channel (MySQL 8.0.22+).
 */
export function buildShowReplicaStatusForChannelSql(replicationChannelName: string): string {
  const ch = replicationChannelName.trim();
  if (!ch) throw new Error("replicationChannelName must be non-empty");
  return `SHOW REPLICA STATUS FOR CHANNEL ${sqlStringLiteral(ch)}`;
}

function slaveStatusFromShowStatusRow(r: Record<string, unknown>): SlaveStatus {
  const io = asString(
    r["Replica_IO_Running"] ??
      r["replica_io_running"] ??
      r["Slave_IO_Running"] ??
      r["slave_io_running"]
  );
  const sqlRunning = asString(
    r["Replica_SQL_Running"] ??
      r["replica_sql_running"] ??
      r["Slave_SQL_Running"] ??
      r["slave_sql_running"]
  );
  const sbm = asNumberOrNull(
    r["Seconds_Behind_Source"] ??
      r["seconds_behind_source"] ??
      r["Seconds_Behind_Master"] ??
      r["seconds_behind_master"]
  );
  const relayFile = asString(
    r["Relay_Source_Log_File"] ??
      r["relay_source_log_file"] ??
      r["Relay_Master_Log_File"] ??
      r["relay_master_log_file"]
  );
  const execPos = asNumberOrNull(
    r["Exec_Source_Log_Pos"] ??
      r["exec_source_log_pos"] ??
      r["Exec_Master_Log_Pos"] ??
      r["exec_master_log_pos"]
  );
  const sourceLogFile = asString(
    r["Source_Log_File"] ??
      r["source_log_file"] ??
      r["Master_Log_File"] ??
      r["master_log_file"]
  );
  const readSourceLogPos = asNumberOrNull(
    r["Read_Source_Log_Pos"] ??
      r["read_source_log_pos"] ??
      r["Read_Master_Log_Pos"] ??
      r["read_master_log_pos"]
  );

  return {
    ioRunning: io,
    sqlRunning,
    secondsBehind: sbm,
    relayMasterLogFile: relayFile,
    execMasterLogPos: execPos,
    sourceLogFile,
    readSourceLogPos,
    lastIoError: asString(r["Last_IO_Error"] ?? r["last_io_error"]),
    lastSqlError: asString(r["Last_SQL_Error"] ?? r["last_sql_error"]),
    lastErrno: asNumberOrNull(r["Last_SQL_Errno"] ?? r["last_sql_errno"]),
  };
}

export async function readReplicaSlaveStatus(pool: Pool, replicationChannelName: string): Promise<SlaveStatus | null> {
  const [rows] = await pool.query(buildShowReplicaStatusForChannelSql(replicationChannelName));
  if (!Array.isArray(rows) || rows.length === 0) return null;
  return slaveStatusFromShowStatusRow(rows[0] as Record<string, unknown>);
}

export type ReplicationApplierWorkerQueryResult =
  | { ok: true; rows: Record<string, unknown>[] }
  | { ok: false; message: string };

/**
 * Reads parallel replication applier worker rows (errors often appear here when
 * `Last_SQL_Error` only points at this table).
 */
export async function fetchReplicationApplierStatusByWorker(pool: Pool): Promise<ReplicationApplierWorkerQueryResult> {
  try {
    const [rows] = await pool.query(
      "SELECT * FROM performance_schema.replication_applier_status_by_worker ORDER BY THREAD_ID"
    );
    if (!Array.isArray(rows)) return { ok: true, rows: [] };
    return { ok: true, rows: rows as Record<string, unknown>[] };
  } catch (e: unknown) {
    const message = e instanceof Error ? e.message : String(e);
    return { ok: false, message };
  }
}

export async function execSql(pool: Pool, sql: string): Promise<void> {
  await pool.query(sql);
}

export async function scalarString(pool: Pool, sql: string): Promise<string | null> {
  const [rows] = await pool.query(sql);
  if (!Array.isArray(rows) || rows.length === 0) return null;
  const r = rows[0] as Record<string, unknown>;
  const firstKey = Object.keys(r)[0];
  if (!firstKey) return null;
  const v = r[firstKey];
  if (v === null || v === undefined) return null;
  return String(v);
}
