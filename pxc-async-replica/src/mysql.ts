import { createPool, type Pool } from "mysql2/promise";
import { asString } from "./primitives";

export type SlaveStatus = {
  ioRunning: string;
  sqlRunning: string;
  secondsBehind: number | null;
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
    throw new Error(`SOURCE_MYSQL_URL is not a valid URL`);
  }
  if (u.protocol !== "mysql:" && u.protocol !== "mysql2:") {
    throw new Error(`SOURCE_MYSQL_URL must use mysql:// or mysql2:// (got ${JSON.stringify(u.protocol)})`);
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
    throw new Error(`SOURCE_MYSQL_URL is not a valid URL`);
  }
  if (u.protocol !== "mysql:" && u.protocol !== "mysql2:") {
    throw new Error(`SOURCE_MYSQL_URL must use mysql:// or mysql2:// (got ${JSON.stringify(u.protocol)})`);
  }
  u.username = user;
  u.password = password;
  return u.toString();
}

function sqlStringLiteral(s: string): string {
  return `'${s.replace(/'/g, "''")}'`;
}

/**
 * SQL for `SHOW SLAVE STATUS` scoped to a named replication channel (matches `REPLICATION_CHANNEL_NAME` / CR channel).
 * Percona/MySQL 8 still accept this form; newer MySQL may prefer `SHOW REPLICA STATUS FOR CHANNEL` if you hit deprecation.
 */
export function buildShowSlaveStatusForChannelSql(replicationChannelName: string): string {
  const ch = replicationChannelName.trim();
  if (!ch) throw new Error("replicationChannelName must be non-empty");
  return `SHOW SLAVE STATUS FOR CHANNEL ${sqlStringLiteral(ch)}`;
}

export async function readReplicaSlaveStatus(pool: Pool, replicationChannelName: string): Promise<SlaveStatus | null> {
  const [rows] = await pool.query(buildShowSlaveStatusForChannelSql(replicationChannelName));
  if (!Array.isArray(rows) || rows.length === 0) return null;
  const r = rows[0] as Record<string, unknown>;

  // mysql2 returns column names as returned by server; keep tolerant access.
  const io = asString(r["Slave_IO_Running"] ?? r["slave_io_running"]);
  const sqlRunning = asString(r["Slave_SQL_Running"] ?? r["slave_sql_running"]);
  const sbm = asNumberOrNull(r["Seconds_Behind_Master"] ?? r["seconds_behind_master"]);

  return {
    ioRunning: io,
    sqlRunning,
    secondsBehind: sbm,
    lastIoError: asString(r["Last_IO_Error"] ?? r["last_io_error"]),
    lastSqlError: asString(r["Last_SQL_Error"] ?? r["last_sql_error"]),
    lastErrno: asNumberOrNull(r["Last_SQL_Errno"] ?? r["last_sql_errno"]),
  };
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
