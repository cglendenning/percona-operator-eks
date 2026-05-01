import * as fs from "fs";
import * as k8s from "@kubernetes/client-node";
import type { Obj } from "./types";
import { log, sleep } from "./log";
import { formatK8sError, isK8sConflict } from "./k8s-errors";
import {
  applyMysqlHostPortToBaseUrl,
  createMysqlPoolFromUrl,
  execSql,
  mergeUserAndPasswordIntoMysqlUrl,
  readReplicaSlaveStatus,
  scalarString,
  type SlaveStatus,
} from "./mysql";
import type { Pool } from "mysql2/promise";
import {
  findLatestBackupS3Destination,
  parseBackupWallTimeUtcMsFromFolderPrefix,
  type S3ClientConfig,
} from "./s3-latest-backup";
import {
  buildDesiredReplicationChannels,
  getClusterReady,
  getPxcSpec,
  patchReplicationChannels,
  verifyReplicationChannels,
} from "./replication";
import {
  appliedCoordsFromSlave,
  formatSlaveStatusLogLine,
  isCatchingUpLag,
  replicationBroken,
  slaveErrorsSuggestMissingSourceBinlogs,
  slaveLooksHealthy,
  type AppliedExecCoords,
} from "./replication-health";
import {
  createRestoreFromS3Destination,
  deleteRestoreCr,
  getRestoreCr,
  isTerminalRestoreFailureState,
  restoreInProgress,
  waitRestoreSucceededAndClusterReady,
  waitUntilRestoreCrAbsent,
} from "./restore";
import { K8S_PATCH_CONTENT_TYPE_OPTIONS } from "./k8s-patch-options";
import {
  extractReplicationSourcesFromPxcBody,
  pickPreferredReplicationSource,
  type ReplicationChannelConnectConfig,
  type SourceEntry,
} from "./channel-normalize";
import { waitUntilTrue } from "./wait-until";
import { retryWithBackoff } from "./transient-errors";

function env(name: string): string {
  const v = process.env[name];
  if (!v) throw new Error(`Missing required env var: ${name}`);
  return v;
}

function envOptional(name: string, defaultValue: string): string {
  return process.env[name] ?? defaultValue;
}

function parseBoolEnv(name: string, defaultValue: boolean): boolean {
  const raw = process.env[name];
  if (!raw) return defaultValue;
  const v = raw.trim().toLowerCase();
  return v === "1" || v === "true" || v === "yes" || v === "y";
}

function parseIntEnv(name: string, defaultValue: number): number {
  const raw = process.env[name];
  if (!raw) return defaultValue;
  const n = parseInt(raw, 10);
  return Number.isFinite(n) ? n : defaultValue;
}

function parseSourceHostList(raw: string): string[] {
  return raw
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean);
}

function decodeSecretData(data: Record<string, string> | undefined, key: string): string {
  if (!data) throw new Error("Secret has no data");
  const b64 = data[key];
  if (!b64) throw new Error(`Secret missing data key: ${key}`);
  return Buffer.from(b64, "base64").toString("utf8").trim();
}

function assertMysqlIdentifier(name: string, label: string): string {
  if (!/^[A-Za-z0-9_]{1,64}$/.test(name)) {
    throw new Error(`${label} must be 1-64 characters [A-Za-z0-9_], got ${JSON.stringify(name)}`);
  }
  return name;
}

/** PerconaXtraDBClusterRestore metadata.name (RFC 1123 subdomain, lowercase). */
function assertBootstrapRestoreCrName(name: string, label: string): string {
  const n = name.trim();
  if (n.length < 1 || n.length > 253) {
    throw new Error(`${label} length must be 1-253, got ${n.length}`);
  }
  if (!/^[a-z0-9]([-a-z0-9]*[a-z0-9])?(\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)*$/.test(n)) {
    throw new Error(`${label} must be a lowercase RFC 1123 subdomain, got ${JSON.stringify(n)}`);
  }
  return n;
}

function sqlString(s: string): string {
  return `'${s.replace(/'/g, "''")}'`;
}

/** Wrap MySQL errors in validateReplication so logs show SOURCE vs REPLICA and which step failed. */
function e2eFail(endpoint: "SOURCE" | "REPLICA", step: string, err: unknown): Error {
  const msg = err instanceof Error ? err.message : formatK8sError(err);
  return new Error(`E2E ${endpoint} failed (${step}): ${msg}`);
}

async function runE2eStep<T>(endpoint: "SOURCE" | "REPLICA", step: string, fn: () => Promise<T>): Promise<T> {
  try {
    return await fn();
  } catch (e: unknown) {
    throw e2eFail(endpoint, step, e);
  }
}

export async function runController(): Promise<void> {
  const DEST_NS = (() => {
    const explicit = process.env.DEST_NS?.trim() || process.env.PXC_NAMESPACE?.trim();
    if (explicit) return explicit;
    const nsPath = "/var/run/secrets/kubernetes.io/serviceaccount/namespace";
    try {
      return fs.readFileSync(nsPath, "utf8").trim();
    } catch {
      throw new Error(`DEST_NS/PXC_NAMESPACE is not set and could not read pod namespace from ${nsPath}`);
    }
  })();
  const PXC_CLUSTER = envOptional("PXC_CLUSTER", "db");
  const isLocal = parseBoolEnv("IS_LOCAL", parseBoolEnv("isLocal", false));
  const CHANNEL_NAME = envOptional("REPLICATION_CHANNEL_NAME", "wookie_primary_to_replica").trim();
  if (!CHANNEL_NAME) throw new Error("REPLICATION_CHANNEL_NAME must be non-empty");

  const allHosts = parseSourceHostList(env("SOURCE_HOSTS"));
  if (allHosts.length === 0) throw new Error("SOURCE_HOSTS must contain at least one hostname");
  const hostsForReplication = isLocal ? allHosts.slice(0, 1) : allHosts;

  const SOURCE_PORT = parseIntEnv("SOURCE_PORT", 3306);
  const SOURCE_WEIGHT = parseIntEnv("SOURCE_WEIGHT", 100);
  /** Percona `replicationChannels[].configuration.sourceRetryCount` (default was 3 in operator). */
  const REPLICATION_SOURCE_RETRY_COUNT = Math.min(
    999_999_999,
    Math.max(1, parseIntEnv("REPLICATION_SOURCE_RETRY_COUNT", 100_000))
  );
  /** Percona `replicationChannels[].configuration.sourceConnectRetry` — seconds between reconnect tries (operator default 60). */
  const REPLICATION_SOURCE_CONNECT_RETRY = Math.min(
    86_400,
    Math.max(1, parseIntEnv("REPLICATION_SOURCE_CONNECT_RETRY", 10))
  );
  const PXC_API_VERSION = envOptional("PXC_API_VERSION", "v1");

  const READY_TIMEOUT_SEC = parseIntEnv("READY_TIMEOUT_SECONDS", 3600);
  const POLL_MS = parseIntEnv("POLL_INTERVAL_MS", 10_000);
  const RESTORE_TIMEOUT_SEC = parseIntEnv("RESTORE_TIMEOUT_SECONDS", 7200);

  const S3_ENDPOINT = env("S3_ENDPOINT_URL");
  const S3_REGION = envOptional("S3_REGION", "us-east-1");
  const S3_FORCE_PATH_STYLE = parseBoolEnv("S3_FORCE_PATH_STYLE", true);
  const S3_BUCKET = envOptional("S3_BACKUP_BUCKET", "pxc-backups");
  const S3_PREFIX = process.env.S3_BACKUP_PREFIX?.trim() ?? "";
  const S3_BACKUP_FOLDER_PREFIX = envOptional("S3_BACKUP_FOLDER_PREFIX", "db-");
  /** Single Secret in DEST_NS: S3 keys, SOURCE/REPLICA MySQL passwords, REPLICA_MYSQL_URL (base), etc. */
  const DB_ROOT_USERS_SECRET = envOptional("DB_ROOT_USERS_SECRET", "db-root-users");

  const MAX_LAG_SECONDS = parseIntEnv("MAX_REPLICATION_LAG_SECONDS", 5);
  const HEALTH_INTERVAL_SEC = parseIntEnv("HEALTHCHECK_INTERVAL_SECONDS", 60);
  const SELF_HEAL_FAILURE_THRESHOLD = parseIntEnv("SELF_HEAL_FAILURE_THRESHOLD", 3);

  const SOURCE_MYSQL_URL_BASE = env("SOURCE_MYSQL_URL");
  const REPLICA_MYSQL_URL_BASE = env("REPLICA_MYSQL_URL");
  /** MySQL user for SOURCE (E2E, SOURCE GATE); password from {@link SOURCE_MYSQL_PASSWORD_SECRET_KEY} in {@link DB_ROOT_USERS_SECRET}. Default `root` → account `root`@`%` on server. */
  const SOURCE_MYSQL_USER = assertMysqlIdentifier(envOptional("SOURCE_MYSQL_USER", "root"), "SOURCE_MYSQL_USER");
  /** Secret data key holding the SOURCE user password (default `root` for `root`@`%`). */
  const SOURCE_MYSQL_PASSWORD_SECRET_KEY = envOptional("SOURCE_MYSQL_PASSWORD_SECRET_KEY", "root");
  /** MySQL user for REPLICA (health loop, E2E); password from {@link REPLICA_MYSQL_PASSWORD_SECRET_KEY} in {@link DB_ROOT_USERS_SECRET}. Default `root`. */
  const REPLICA_MYSQL_USER = assertMysqlIdentifier(envOptional("REPLICA_MYSQL_USER", "root"), "REPLICA_MYSQL_USER");
  /** Secret data key holding the REPLICA user password (default `root`). */
  const REPLICA_MYSQL_PASSWORD_SECRET_KEY = envOptional("REPLICA_MYSQL_PASSWORD_SECRET_KEY", "root");
  const E2E_DB = assertMysqlIdentifier(envOptional("REPLICATION_E2E_DATABASE", "mysql"), "REPLICATION_E2E_DATABASE");
  const E2E_TABLE = assertMysqlIdentifier(
    envOptional("REPLICATION_E2E_TABLE", "pxc_async_replica_test"),
    "REPLICATION_E2E_TABLE"
  );
  const BOOTSTRAP_RESTORE_CR_NAME = assertBootstrapRestoreCrName(
    envOptional("PXC_BOOTSTRAP_RESTORE_CR_NAME", "async-replica-bootstrap"),
    "PXC_BOOTSTRAP_RESTORE_CR_NAME"
  );
  const RESTORE_DELETE_WAIT_MS = parseIntEnv("RESTORE_DELETE_WAIT_MS", 120_000);
  /** Total wall time between re-seed attempts (Phase A restore or post-reseed phases): steps × step duration. Default 5×1m = 5m. */
  const RESEED_RETRY_STEP_MS = parseIntEnv("RESEED_RETRY_STEP_MS", 60_000);
  const RESEED_RETRY_STEPS = parseIntEnv("RESEED_RETRY_STEPS", 5);
  const BINLOG_GAP_ADVICE_COOLDOWN_MS = parseIntEnv("BINLOG_GAP_ADVICE_COOLDOWN_MS", 600_000);

  let shuttingDown = false;
  let lastBinlogGapAdviceAt = 0;
  let lastBinlogGapAdviceFp = "";
  const shutdown = () => {
    shuttingDown = true;
    log("SIGTERM/SIGINT received, shutting down gracefully");
  };
  process.on("SIGTERM", shutdown);
  process.on("SIGINT", shutdown);

  try {
  const kc = new k8s.KubeConfig();
  kc.loadFromDefault();
  const core = kc.makeApiClient(k8s.CoreV1Api);
  const custom = kc.makeApiClient(k8s.CustomObjectsApi);
  const apps = kc.makeApiClient(k8s.AppsV1Api);

  const dbRootSecret = await retryWithBackoff({
    label: `readNamespacedSecret(${DB_ROOT_USERS_SECRET})`,
    fn: () => core.readNamespacedSecret({ namespace: DEST_NS, name: DB_ROOT_USERS_SECRET }),
    maxAttempts: parseIntEnv("K8S_STARTUP_READ_SECRET_MAX_ATTEMPTS", 60),
    baseDelayMs: parseIntEnv("K8S_RETRY_BASE_DELAY_MS", 1000),
    maxDelayMs: parseIntEnv("K8S_RETRY_MAX_DELAY_MS", 60_000),
    isShuttingDown: () => shuttingDown,
  });
  const dbRootData = dbRootSecret.data as Record<string, string> | undefined;
  if (!dbRootData) throw new Error(`Secret ${DB_ROOT_USERS_SECRET} has no data`);

  const sourceMysqlPassword = decodeSecretData(dbRootData, SOURCE_MYSQL_PASSWORD_SECRET_KEY);
  const sourceMysqlUrlFromEnv = mergeUserAndPasswordIntoMysqlUrl(
    SOURCE_MYSQL_URL_BASE,
    SOURCE_MYSQL_USER,
    sourceMysqlPassword
  );
  const replicaMysqlPassword = decodeSecretData(dbRootData, REPLICA_MYSQL_PASSWORD_SECRET_KEY);
  const replicaMysqlUrl = mergeUserAndPasswordIntoMysqlUrl(
    REPLICA_MYSQL_URL_BASE,
    REPLICA_MYSQL_USER,
    replicaMysqlPassword
  );

  const sources: SourceEntry[] = hostsForReplication.map((host) => ({
    host,
    port: SOURCE_PORT,
    weight: SOURCE_WEIGHT,
  }));
  const replicationConnectConfig: ReplicationChannelConnectConfig = {
    sourceRetryCount: REPLICATION_SOURCE_RETRY_COUNT,
    sourceConnectRetry: REPLICATION_SOURCE_CONNECT_RETRY,
  };
  const desiredChannels = buildDesiredReplicationChannels({
    channelName: CHANNEL_NAME,
    sources,
    connectConfig: replicationConnectConfig,
  });
  const pxcRef = { pxcApiVersion: PXC_API_VERSION, ns: DEST_NS, cluster: PXC_CLUSTER } as const;

  const SOURCE_RESOLVE_FROM_CLUSTER = parseBoolEnv("SOURCE_RESOLVE_FROM_CLUSTER", true);
  let lastLoggedSourceEndpoint = "";

  /**
   * MySQL URL for the async **source** used by E2E and SOURCE GATE. When {@link SOURCE_RESOLVE_FROM_CLUSTER}
   * is true, host/port are taken from the live `PerconaXtraDBCluster` `spec.pxc.replicationChannels` entry
   * for {@link CHANNEL_NAME} (same sources the operator configured for replication), not only `SOURCE_MYSQL_URL`.
   */
  async function resolveActiveSourceMysqlUrl(): Promise<string> {
    if (!SOURCE_RESOLVE_FROM_CLUSTER) return sourceMysqlUrlFromEnv;
    const body = await getPxcSpec(custom, pxcRef);
    const live = extractReplicationSourcesFromPxcBody(body, CHANNEL_NAME, SOURCE_PORT);
    if (live && live.length > 0) {
      const pick = pickPreferredReplicationSource(live);
      const withHost = applyMysqlHostPortToBaseUrl(SOURCE_MYSQL_URL_BASE, pick.host, pick.port);
      const merged = mergeUserAndPasswordIntoMysqlUrl(withHost, SOURCE_MYSQL_USER, sourceMysqlPassword);
      const tag = `${pick.host}:${pick.port}`;
      if (tag !== lastLoggedSourceEndpoint) {
        lastLoggedSourceEndpoint = tag;
        log(
          `SOURCE MySQL from live replicationChannels[${CHANNEL_NAME}]: ${tag} ` +
            `(preferred of ${live.length} source(s) by weight, then host name)`
        );
      }
      return merged;
    }
    if (lastLoggedSourceEndpoint !== "__env__") {
      lastLoggedSourceEndpoint = "__env__";
      log(
        `SOURCE MySQL from env (no usable spec.pxc.replicationChannels sourcesList for channel ${CHANNEL_NAME})`
      );
    }
    return sourceMysqlUrlFromEnv;
  }

  log(
    `pxc-async-replica-controller starting destNs=${DEST_NS} cluster=${PXC_CLUSTER} channel=${CHANNEL_NAME} ` +
      `SOURCE_HOSTS(${allHosts.length})=${allHosts.join(",")} replicationHosts(${hostsForReplication.length})=${hostsForReplication.join(",")} ` +
      `SOURCE_RESOLVE_FROM_CLUSTER=${SOURCE_RESOLVE_FROM_CLUSTER} ` +
      `REPLICATION_SOURCE_RETRY_COUNT=${REPLICATION_SOURCE_RETRY_COUNT} REPLICATION_SOURCE_CONNECT_RETRY=${REPLICATION_SOURCE_CONNECT_RETRY}s ` +
      `dbRootSecret=${DB_ROOT_USERS_SECRET} (SOURCE password key=${SOURCE_MYSQL_PASSWORD_SECRET_KEY}) SOURCE_MYSQL_USER=${SOURCE_MYSQL_USER} ` +
      `(REPLICA password key=${REPLICA_MYSQL_PASSWORD_SECRET_KEY}) REPLICA_MYSQL_USER=${REPLICA_MYSQL_USER} ` +
      `S3_ENDPOINT=${S3_ENDPOINT} S3_BUCKET=${S3_BUCKET} S3_PREFIX=${S3_PREFIX || "<none>"} S3_BACKUP_FOLDER_PREFIX=${S3_BACKUP_FOLDER_PREFIX}`
  );
  if (isLocal && allHosts.length > 1) {
    log(`IS_LOCAL=true: using first SOURCE_HOST only (${hostsForReplication[0]})`);
  }

  async function waitClusterReadyOrThrow(): Promise<void> {
    const deadline = Date.now() + READY_TIMEOUT_SEC * 1000;
    while (!shuttingDown && Date.now() < deadline) {
      const ok = await getClusterReady(custom, pxcRef);
      if (ok) return;
      const body = await getPxcSpec(custom, pxcRef);
      const status = body?.status as Obj | undefined;
      const state = typeof status?.state === "string" ? status.state : "";
      const msg = typeof status?.message === "string" ? status.message : "";
      log(`Waiting for cluster ready: state="${state}" message=${msg ? JSON.stringify(msg) : "none"}`);
      await sleep(POLL_MS);
    }
    throw new Error(`Timed out after ${READY_TIMEOUT_SEC}s waiting for cluster ${PXC_CLUSTER} ready`);
  }

  function loadS3CfgFromDbRootSecret(): S3ClientConfig {
    return {
      endpoint: S3_ENDPOINT,
      region: S3_REGION,
      forcePathStyle: S3_FORCE_PATH_STYLE,
      accessKeyId: decodeSecretData(dbRootData, "AWS_ACCESS_KEY_ID"),
      secretAccessKey: decodeSecretData(dbRootData, "AWS_SECRET_ACCESS_KEY"),
    };
  }

  async function restoreFromLatestSeaweedBackup(): Promise<boolean> {
    const s3cfg = loadS3CfgFromDbRootSecret();
    const listPrefix = `${S3_PREFIX}${S3_BACKUP_FOLDER_PREFIX}`;
    const latest = await findLatestBackupS3Destination({
      cfg: s3cfg,
      bucket: S3_BUCKET,
      prefix: listPrefix.length > 0 ? listPrefix : undefined,
    });
    log(`Selected latest backup destination=${latest.destination} (chosenPrefix=${latest.chosenPrefix}, listPrefix=${JSON.stringify(listPrefix)})`);

    const restoreName = BOOTSTRAP_RESTORE_CR_NAME;

    const existingEarly = await getRestoreCr(custom, {
      pxcApiVersion: pxcRef.pxcApiVersion,
      ns: pxcRef.ns,
      restoreName,
    });
    if (existingEarly) {
      const stEarly = (existingEarly.status as Obj | undefined)?.state;
      const stateEarly = typeof stEarly === "string" ? stEarly : "";
      const destEarly = (() => {
        const spec = existingEarly.spec as Obj | undefined;
        const src = spec?.backupSource as Obj | undefined;
        return typeof src?.destination === "string" ? src.destination : undefined;
      })();
      const staleSucceeded =
        stateEarly === "Succeeded" && destEarly !== undefined && destEarly !== latest.destination;
      if (isTerminalRestoreFailureState(stateEarly) || staleSucceeded) {
        const reason = staleSucceeded
          ? `backup source changed (stored=${JSON.stringify(destEarly)} latest=${JSON.stringify(latest.destination)})`
          : `state=${JSON.stringify(stateEarly)}`;
        log(`Removing bootstrap restore CR ${restoreName} (${reason}) before retry`);
        await deleteRestoreCr(custom, {
          pxcApiVersion: pxcRef.pxcApiVersion,
          ns: pxcRef.ns,
          restoreName,
        });
        await waitUntilRestoreCrAbsent({
          custom,
          pxcApiVersion: pxcRef.pxcApiVersion,
          ns: pxcRef.ns,
          restoreName,
          timeoutMs: RESTORE_DELETE_WAIT_MS,
          pollMs: POLL_MS,
          isShuttingDown: () => shuttingDown,
        });
      }
    }

    if (await restoreInProgress(custom, { pxcApiVersion: pxcRef.pxcApiVersion, ns: pxcRef.ns })) {
      log("Restore already in progress in this namespace; waiting for cluster ready (external restore)");
      await waitClusterReadyOrThrow();
      return false;
    }

    const existing = await getRestoreCr(custom, {
      pxcApiVersion: pxcRef.pxcApiVersion,
      ns: pxcRef.ns,
      restoreName,
    });
    let needCreate = true;
    if (existing) {
      const st = (existing.status as Obj | undefined)?.state;
      const state = typeof st === "string" ? st : "";
      if (state === "Starting" || state === "Running" || state === "Succeeded") {
        log(`Reusing existing restore CR ${restoreName} state=${state || "(empty)"}`);
        needCreate = false;
      } else if (!isTerminalRestoreFailureState(state) && state !== "") {
        log(`Restore CR ${restoreName} in state=${JSON.stringify(state)}; will poll without creating a duplicate`);
        needCreate = false;
      }
    }

    if (needCreate) {
      try {
        await createRestoreFromS3Destination(custom, {
          pxcApiVersion: pxcRef.pxcApiVersion,
          ns: pxcRef.ns,
          cluster: pxcRef.cluster,
          restoreName,
          destination: latest.destination,
          s3: {
            credentialsSecret: DB_ROOT_USERS_SECRET,
            region: S3_REGION,
            endpointUrl: S3_ENDPOINT,
            forcePathStyle: S3_FORCE_PATH_STYLE,
          },
        });
      } catch (e: unknown) {
        if (isK8sConflict(e)) {
          log(`Restore CR ${restoreName} already exists (409); adopting and polling status`);
        } else {
          throw e;
        }
      }
    }

    const result = await waitRestoreSucceededAndClusterReady({
      custom,
      pxcApiVersion: pxcRef.pxcApiVersion,
      ns: pxcRef.ns,
      cluster: pxcRef.cluster,
      restoreName,
      timeoutSeconds: RESTORE_TIMEOUT_SEC,
      pollMs: POLL_MS,
      isShuttingDown: () => shuttingDown,
    });

    if (result !== "succeeded") {
      throw new Error(`Restore did not succeed (result=${result}, restore=${restoreName})`);
    }
    return true;
  }

  /**
   * When replica errors look like missing/purged source binlogs, log stream coordinates vs latest DR/S3 backup
   * so operators can tell when the gap is past the newest restorable snapshot (must wait for a newer backup).
   */
  async function logBinlogGapVersusLatestDrBackupIfRelevant(s: SlaveStatus, reason: string): Promise<void> {
    if (!slaveErrorsSuggestMissingSourceBinlogs(s)) return;
    const fp = `${s.lastIoError}|${s.lastSqlError}|${s.relayMasterLogFile}|${s.execMasterLogPos ?? ""}|${s.sourceLogFile}|${s.readSourceLogPos ?? ""}`;
    const now = Date.now();
    if (fp === lastBinlogGapAdviceFp && now - lastBinlogGapAdviceAt < BINLOG_GAP_ADVICE_COOLDOWN_MS) return;
    lastBinlogGapAdviceFp = fp;
    lastBinlogGapAdviceAt = now;

    log(
      `BINLOG_GAP (${reason}): errors suggest source binary logs are unavailable. Stream position: SQL applied through ` +
        `${s.relayMasterLogFile}:${s.execMasterLogPos ?? "null"}; IO thread read ` +
        `${s.sourceLogFile || "(unknown)"}:${s.readSourceLogPos ?? "null"}. ` +
        `Last_IO_Error=${JSON.stringify(s.lastIoError)} Last_SQL_Error=${JSON.stringify(s.lastSqlError)}`
    );

    try {
      const s3cfg = loadS3CfgFromDbRootSecret();
      const listPrefix = `${S3_PREFIX}${S3_BACKUP_FOLDER_PREFIX}`;
      const latest = await findLatestBackupS3Destination({
        cfg: s3cfg,
        bucket: S3_BUCKET,
        prefix: listPrefix.length > 0 ? listPrefix : undefined,
      });
      const tsMs = parseBackupWallTimeUtcMsFromFolderPrefix(latest.chosenPrefix);
      const iso = tsMs !== null ? new Date(tsMs).toISOString() : "unknown";
      log(
        `BINLOG_GAP: latest DR/S3 full backup used for re-seed is ${JSON.stringify(latest.chosenPrefix)} ` +
          `(folder timestamp ≈ ${iso} UTC). destination=${latest.destination}`
      );
      log(
        `BINLOG_GAP: If the first missing or unavailable events on the source binlog stream are **after** that backup time, ` +
          `a restore from this snapshot cannot bring the replica fully current until a **newer** full backup exists on the filer. ` +
          `The controller picks the newest S3 prefix on each re-seed; when a backup newer than ${iso} UTC is published, the next restore can succeed.`
      );
    } catch (e: unknown) {
      log(`BINLOG_GAP: could not list latest DR backup for comparison: ${formatK8sError(e)}`);
    }
  }

  async function applyReplicationIfNeeded(): Promise<void> {
    const initial = await getPxcSpec(custom, pxcRef);
    const initialSpec = initial?.spec as Obj | undefined;
    const initialPxc = initialSpec?.pxc as Obj | undefined;
    const existing = initialPxc?.replicationChannels;

    const already = await verifyReplicationChannels(custom, {
      ...pxcRef,
      desired: desiredChannels,
      clusterBody: initial,
    });
    if (already) {
      log("replicationChannels already match desired; skipping patch");
      return;
    }

    log(`Current replicationChannels: ${JSON.stringify(existing)}`);
    await patchReplicationChannels(custom, {
      ...pxcRef,
      channels: desiredChannels,
    });
    await sleep(3000);

    if (!(await verifyReplicationChannels(custom, { ...pxcRef, desired: desiredChannels }))) {
      throw new Error("VERIFY FAILED: replicationChannels do not match desired after patch");
    }
  }

  async function waitMysqlReplicationHealthy(pool: Pool): Promise<void> {
    const deadline = Date.now() + READY_TIMEOUT_SEC * 1000;
    while (!shuttingDown && Date.now() < deadline) {
      const s = await readReplicaSlaveStatus(pool, CHANNEL_NAME);
      if (!s) {
        log("Replication check: SHOW REPLICA STATUS returned no rows (replication not configured yet?)");
      } else {
        log(`Replication check: ${formatSlaveStatusLogLine(s)}`);
        if (slaveLooksHealthy(s, MAX_LAG_SECONDS)) return;
      }
      await sleep(POLL_MS);
    }
    throw new Error(`Timed out after ${READY_TIMEOUT_SEC}s waiting for replication lag<=${MAX_LAG_SECONDS}s`);
  }

  /**
   * Row-level write probe: ensure fixed E2E table exists, TRUNCATE + INSERT on source, verify on replica,
   * TRUNCATE on source, verify empty on replica. Reuses a single table name (default pxc_async_replica_test);
   * no per-run random DDL names.
   * Not a read-only check; requires privileges on `REPLICATION_E2E_DATABASE`.
   */
  async function validateReplication(): Promise<void> {
    const sourceMysqlUrlActive = await resolveActiveSourceMysqlUrl();
    const sourcePool = createMysqlPoolFromUrl(sourceMysqlUrlActive);
    const replicaPool = createMysqlPoolFromUrl(replicaMysqlUrl);

    const fqtn = `${E2E_DB}.${E2E_TABLE}`;
    const rowCountSql = `SELECT COUNT(*) FROM ${fqtn}`;

    try {
      log(`E2E: ensuring table ${fqtn} on SOURCE, truncate, insert probe row (database=${E2E_DB})`);
      await runE2eStep("SOURCE", "CREATE DATABASE IF NOT EXISTS", () =>
        execSql(sourcePool, `CREATE DATABASE IF NOT EXISTS ${E2E_DB}`)
      );
      await runE2eStep("SOURCE", "CREATE TABLE IF NOT EXISTS", () =>
        execSql(sourcePool, `CREATE TABLE IF NOT EXISTS ${fqtn} (id INT PRIMARY KEY, note VARCHAR(128))`)
      );
      await runE2eStep("SOURCE", "TRUNCATE before probe", () => execSql(sourcePool, `TRUNCATE TABLE ${fqtn}`));
      const note = `hello-${Date.now()}`;
      await runE2eStep("SOURCE", "INSERT test row", () =>
        execSql(sourcePool, `INSERT INTO ${fqtn} (id, note) VALUES (1, ${sqlString(note)})`)
      );

      log("E2E: waiting for row to appear on REPLICA");
      const rowOk = await waitUntilTrue({
        pollMs: 500,
        deadlineMs: READY_TIMEOUT_SEC * 1000,
        isShuttingDown: () => shuttingDown,
        predicate: async () => {
          try {
            return (await scalarString(replicaPool, `SELECT note FROM ${fqtn} WHERE id=1`)) === note;
          } catch (e: unknown) {
            throw e2eFail("REPLICA", "SELECT replicated row (poll)", e);
          }
        },
      });
      if (!rowOk) {
        const got = await runE2eStep("REPLICA", "SELECT replicated row (final read)", () =>
          scalarString(replicaPool, `SELECT note FROM ${fqtn} WHERE id=1`)
        );
        throw new Error(`E2E REPLICA: row did not match after wait (expected note=${JSON.stringify(note)} got=${JSON.stringify(got)})`);
      }
      log("E2E: replicated row verified on REPLICA");

      log(`E2E: truncating ${fqtn} on SOURCE after successful probe`);
      await runE2eStep("SOURCE", "TRUNCATE after probe", () => execSql(sourcePool, `TRUNCATE TABLE ${fqtn}`));

      log("E2E: waiting for TRUNCATE to replicate to REPLICA (row count 0)");
      const emptyOk = await waitUntilTrue({
        pollMs: 500,
        deadlineMs: READY_TIMEOUT_SEC * 1000,
        isShuttingDown: () => shuttingDown,
        predicate: async () => {
          try {
            return (await scalarString(replicaPool, rowCountSql)) === "0";
          } catch (e: unknown) {
            throw e2eFail("REPLICA", "SELECT row count after TRUNCATE (poll)", e);
          }
        },
      });
      if (emptyOk) {
        log("E2E: truncate replicated; table empty on REPLICA");
        return;
      }

      const cnt2 = await runE2eStep("REPLICA", "SELECT row count (final read)", () => scalarString(replicaPool, rowCountSql));
      throw new Error(`E2E REPLICA: table not empty after TRUNCATE wait (row count=${cnt2})`);
    } finally {
      await sourcePool.end().catch(() => {});
      await replicaPool.end().catch(() => {});
    }
  }

  /**
   * Blocks until the SOURCE MySQL endpoint is reachable and can execute a trivial query.
   * Uses the same pacing as the main health loop.
   */
  async function waitUntilSourceReachable(logPrefix = "SOURCE GATE"): Promise<void> {
    const intervalSec = HEALTH_INTERVAL_SEC;
    let attempt = 0;
    while (!shuttingDown) {
      attempt += 1;
      try {
        const url = await resolveActiveSourceMysqlUrl();
        const p = createMysqlPoolFromUrl(url);
        try {
          await scalarString(p, "SELECT 1");
        } finally {
          await p.end().catch(() => {});
        }
        log(`${logPrefix}: SOURCE MySQL accepts queries (SELECT 1) (attempt ${attempt})`);
        return;
      } catch (e: unknown) {
        const detail = e instanceof Error ? e.message : formatK8sError(e);
        log(
          `${logPrefix}: SOURCE MySQL not ready (${detail}). ` +
            `Not proceeding with restore, bootstrap, or self-heal. Will retry every ${intervalSec}s (network, credentials, or privileges may still be wrong). (attempt ${attempt})`
        );
        const total = intervalSec * 1000;
        const step = 1000;
        let waited = 0;
        while (!shuttingDown && waited < total) {
          await sleep(Math.min(step, total - waited));
          waited += step;
        }
      }
    }
  }

  /** True if a full end-to-end replicated write/drop succeeds; false on any failure (no throw). */
  async function tryE2eFirstReplicationGate(): Promise<boolean> {
    if (shuttingDown) {
      log("E2E-first gate: shutdown requested before gate ran");
      return false;
    }
    try {
      await validateReplication();
      return true;
    } catch (e: unknown) {
      const detail = e instanceof Error ? e.message : formatK8sError(e);
      log(`E2E-first gate did not pass — ${detail}`);
      return false;
    }
  }

  async function waitReseedRetryWindow(reason: string): Promise<void> {
    const totalMin = (RESEED_RETRY_STEPS * RESEED_RETRY_STEP_MS) / 60_000;
    log(
      `${reason} Waiting ${RESEED_RETRY_STEPS}×${RESEED_RETRY_STEP_MS / 1000}s (~${totalMin} min total) before next re-seed attempt.`
    );
    for (let step = 1; step <= RESEED_RETRY_STEPS && !shuttingDown; step++) {
      log(`  re-seed cooldown step ${step}/${RESEED_RETRY_STEPS}`);
      let waited = 0;
      while (!shuttingDown && waited < RESEED_RETRY_STEP_MS) {
        const chunk = Math.min(1000, RESEED_RETRY_STEP_MS - waited);
        await sleep(chunk);
        waited += chunk;
      }
    }
  }

  async function reseedThenValidateWithRetry(args: { pool: Pool; context: "BOOTSTRAP" | "SELF-HEAL" }): Promise<void> {
    type PostReseedStage =
      | "cluster_ready"
      | "apply_replication_channels"
      | "wait_replication_healthy"
      | "validate_replication_e2e";

    const stageLabel = (stage: PostReseedStage): string => {
      switch (stage) {
        case "cluster_ready":
          return "wait cluster ready";
        case "apply_replication_channels":
          return "apply replicationChannels";
        case "wait_replication_healthy":
          return "wait replication healthy";
        case "validate_replication_e2e":
          return "validate replication e2e";
      }
    };

    while (!shuttingDown) {
      if (args.context === "BOOTSTRAP") log("Phase A: restore latest backup from Seaweed S3 (if needed)");
      let reseedPerformed: boolean;
      try {
        reseedPerformed = await restoreFromLatestSeaweedBackup();
      } catch (e: unknown) {
        const detail = e instanceof Error ? e.message : formatK8sError(e);
        log(`${args.context}: Phase A restore-from-latest failed: ${detail}. Applying re-seed cooldown before retry.`);
        await waitReseedRetryWindow(`${args.context}:`);
        continue;
      }

      let stage: PostReseedStage = "cluster_ready";
      try {
        if (args.context === "BOOTSTRAP") log("Phase B: wait for PXC cluster ready after restore/bootstrap");
        stage = "cluster_ready";
        await waitClusterReadyOrThrow();
        if (args.context === "BOOTSTRAP") log("Phase C: apply replicationChannels after restore + ready");
        stage = "apply_replication_channels";
        await applyReplicationIfNeeded();
        if (args.context === "BOOTSTRAP") log(`Phase D: wait for async replication health (lag<=${MAX_LAG_SECONDS}s)`);
        stage = "wait_replication_healthy";
        await waitMysqlReplicationHealthy(args.pool);
        if (args.context === "BOOTSTRAP") log("Phase E: replication validation (source->replica->drop)");
        stage = "validate_replication_e2e";
        await validateReplication();
        return;
      } catch (e: unknown) {
        if (!reseedPerformed) throw e;
        const detail = e instanceof Error ? e.message : formatK8sError(e);
        if (stage === "validate_replication_e2e") {
          log(
            `${args.context}: replication validation failed despite a full re-seed: ${detail}. ` +
              "Entering re-seed cooldown before attempting another re-seed."
          );
        } else {
          log(
            `${args.context}: post-reseed step failed before replication validation ` +
              `(stage=${stageLabel(stage)}): ${detail}. Entering re-seed cooldown before attempting another re-seed.`
          );
        }
        await waitReseedRetryWindow(`${args.context}:`);
      }
    }
  }

  async function runFullBootstrapPhases(pool: Pool): Promise<void> {
    await reseedThenValidateWithRetry({ pool, context: "BOOTSTRAP" });
  }

  async function tryRestartWorkloadByLabels(args: { appLabel: string; component: string; object: "statefulset" | "deployment" }): Promise<boolean> {
    const labelSelector = `app.kubernetes.io/name=${args.appLabel},app.kubernetes.io/component=${args.component}`;
    const patch = { spec: { template: { metadata: { annotations: { "pxc-async-replica/restartedAt": new Date().toISOString() } } } } };
    try {
      if (args.object === "statefulset") {
        const resp = await apps.listNamespacedStatefulSet({ namespace: DEST_NS, labelSelector });
        const items = resp.items ?? [];
        if (items.length === 0) {
          log(`SELF-HEAL: no StatefulSet matched selector ${labelSelector}`);
          return false;
        }
        const name = items[0].metadata?.name;
        if (!name) return false;
        log(`SELF-HEAL: restarting StatefulSet/${name} (${labelSelector})`);
        await apps.patchNamespacedStatefulSet({ namespace: DEST_NS, name, body: patch }, K8S_PATCH_CONTENT_TYPE_OPTIONS);
        return true;
      }

      const resp = await apps.listNamespacedDeployment({ namespace: DEST_NS, labelSelector });
      const items = resp.items ?? [];
      if (items.length === 0) {
        log(`SELF-HEAL: no Deployment matched selector ${labelSelector}`);
        return false;
      }
      const name = items[0].metadata?.name;
      if (!name) return false;
      log(`SELF-HEAL: restarting Deployment/${name} (${labelSelector})`);
      await apps.patchNamespacedDeployment({ namespace: DEST_NS, name, body: patch }, K8S_PATCH_CONTENT_TYPE_OPTIONS);
      return true;
    } catch (e: unknown) {
      log(`SELF-HEAL: restart failed: ${formatK8sError(e)}`);
      return false;
    }
  }

  /** IO/SQL running and no slave errors, but lag above threshold or lag unknown — not yet a candidate for immediate re-seed. */
  function isLagOnlyUnhealthy(s: SlaveStatus | null): boolean {
    return !!s && !replicationBroken(s) && !slaveLooksHealthy(s, MAX_LAG_SECONDS);
  }

  /**
   * When unhealthy is lag-only, wait for up to 5 replica status checks spaced 1 minute apart before allowing re-seed.
   * @returns true if replication became healthy (caller should skip re-seed), false if still unhealthy after all attempts.
   */
  async function waitLagOnlyBeforeReseed(pool: Pool): Promise<boolean> {
    const attempts = 5;
    const delayMs = 60_000;
    for (let i = 1; i <= attempts; i++) {
      if (shuttingDown) return true;
      const st = await readReplicaSlaveStatus(pool, CHANNEL_NAME);
      const ok = !!st && !replicationBroken(st) && slaveLooksHealthy(st, MAX_LAG_SECONDS);
      if (ok) {
        log(`SELF-HEAL: lag watch ${i}/${attempts}: replication healthy; skipping re-seed`);
        return true;
      }
      log(`SELF-HEAL: lag watch ${i}/${attempts}: still lagging or lag unknown`);
      if (i < attempts) {
        let waited = 0;
        while (!shuttingDown && waited < delayMs) {
          const step = Math.min(1000, delayMs - waited);
          await sleep(step);
          waited += step;
        }
      }
    }
    return false;
  }

  async function selfHealReplication(args: { replicaPool: Pool; attempt: number }): Promise<void> {
    log(`SELF-HEAL: attempt ${args.attempt} starting (threshold=${SELF_HEAL_FAILURE_THRESHOLD})`);

    // 1) Re-assert desired replicationChannels (covers drift / partial application)
    try {
      log("SELF-HEAL: re-applying replicationChannels (merge patch)");
      await patchReplicationChannels(custom, { ...pxcRef, channels: desiredChannels });
      await sleep(3000);
      await verifyReplicationChannels(custom, { ...pxcRef, desired: desiredChannels });
    } catch (e: unknown) {
      log(`SELF-HEAL: replication patch/verify failed: ${formatK8sError(e)}`);
    }

    // 2) Try restarting HAProxy then PXC workloads (common names)
    const haproxyName = envOptional("HAPROXY_APP_LABEL", PXC_CLUSTER);
    await tryRestartWorkloadByLabels({ appLabel: haproxyName, component: "haproxy", object: "deployment" });
    await sleep(10_000);

    const pxcName = envOptional("PXC_APP_LABEL", PXC_CLUSTER);
    await tryRestartWorkloadByLabels({ appLabel: pxcName, component: "pxc", object: "statefulset" });
    await sleep(10_000);

    // 3) Last resort: restore from latest Seaweed backup again
    if (args.attempt >= SELF_HEAL_FAILURE_THRESHOLD) {
      const st = await readReplicaSlaveStatus(args.replicaPool, CHANNEL_NAME);
      if (isLagOnlyUnhealthy(st)) {
        log(
          "SELF-HEAL: replication appears lag-only (IO/SQL Yes, no slave errors); 5 status checks at 1m spacing before re-seed"
        );
        const recovered = await waitLagOnlyBeforeReseed(args.replicaPool);
        if (recovered) return;
      }
      log("SELF-HEAL: escalating to full restore-from-latest-backup");
      if (st && replicationBroken(st) && slaveErrorsSuggestMissingSourceBinlogs(st)) {
        await logBinlogGapVersusLatestDrBackupIfRelevant(st, "SELF-HEAL before restore-from-latest");
      }
      await reseedThenValidateWithRetry({ pool: args.replicaPool, context: "SELF-HEAL" });
    }
  }

  // --- Main orchestration ---
  const replicaPool = createMysqlPoolFromUrl(replicaMysqlUrl);

  try {
    log("SOURCE GATE: waiting until SOURCE MySQL accepts a trivial query (SELECT 1) (no restore/bootstrap until then)");
    await waitUntilSourceReachable();
    if (shuttingDown) {
      log("SOURCE GATE: shutdown requested; exiting before Phase 0");
      return;
    }

    log(
      "Phase 0: E2E-first gate — row-level replication test on source/replica (insert, verify, drop, verify)"
    );
    const gateOk = await tryE2eFirstReplicationGate();
    if (gateOk) {
      log("E2E-first gate passed: replication verified; skipping Phases A–E");
    } else {
      log("E2E-first gate did not pass; running full bootstrap Phases A–E");
      await runFullBootstrapPhases(replicaPool);
    }

    log(`Phase F: periodic replication health checks every ${HEALTH_INTERVAL_SEC}s`);
    let failStreak = 0;
    let previousAppliedCoords: AppliedExecCoords | null = null;

    while (!shuttingDown) {
      const s = await readReplicaSlaveStatus(replicaPool, CHANNEL_NAME);
      if (!s) {
        log("HEALTH: SHOW REPLICA STATUS returned no rows");
      } else {
        log(`HEALTH: ${formatSlaveStatusLogLine(s)}`);
        if (replicationBroken(s) && slaveErrorsSuggestMissingSourceBinlogs(s)) {
          await logBinlogGapVersusLatestDrBackupIfRelevant(s, "HEALTH periodic");
        }
      }

      const catchingUp = !!s && isCatchingUpLag(s, MAX_LAG_SECONDS, previousAppliedCoords);

      const healthy = !!s && slaveLooksHealthy(s, MAX_LAG_SECONDS) && !replicationBroken(s);
      if (healthy) {
        failStreak = 0;
      } else if (catchingUp) {
        failStreak = 0;
        log(
          `HEALTH: replica is behind (Seconds_Behind_Master=${s!.secondsBehind ?? "null"}s) but IO/SQL threads are running ` +
            `and applied position has advanced since the last check; no recovery action (next check in ${HEALTH_INTERVAL_SEC}s)`
        );
      } else {
        log("HEALTH: replication unhealthy — waiting for source reachability before any recovery action");
        await waitUntilSourceReachable("SOURCE GATE (replication unhealthy)");
        if (shuttingDown) break;
        const s2 = await readReplicaSlaveStatus(replicaPool, CHANNEL_NAME);
        const healthyNow = !!s2 && slaveLooksHealthy(s2, MAX_LAG_SECONDS) && !replicationBroken(s2);
        if (healthyNow) {
          log("HEALTH: replication healthy after source reachability gate; skipping self-heal");
          failStreak = 0;
        } else {
          failStreak += 1;
          log(`HEALTH: still unhealthy after source reachability gate (failStreak=${failStreak}); running self-heal`);
          if (s2 && replicationBroken(s2) && slaveErrorsSuggestMissingSourceBinlogs(s2)) {
            await logBinlogGapVersusLatestDrBackupIfRelevant(s2, "HEALTH post source-gate");
          }
          await selfHealReplication({ replicaPool, attempt: failStreak });
        }
      }

      if (s) {
        previousAppliedCoords = appliedCoordsFromSlave(s);
      } else {
        previousAppliedCoords = null;
      }

      // Sleep in small chunks so SIGTERM is responsive.
      const total = HEALTH_INTERVAL_SEC * 1000;
      const step = 1000;
      let waited = 0;
      while (!shuttingDown && waited < total) {
        await sleep(Math.min(step, total - waited));
        waited += step;
      }

    }

    log("Shutdown complete");
  } finally {
    await replicaPool.end().catch(() => {});
  }
  } finally {
    process.off("SIGTERM", shutdown);
    process.off("SIGINT", shutdown);
  }
}
