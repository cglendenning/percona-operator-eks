import * as crypto from "crypto";
import * as fs from "fs";
import * as k8s from "@kubernetes/client-node";
import type { Obj } from "./types";
import { log, sleep } from "./log";
import { formatK8sError } from "./k8s-errors";
import {
  createMysqlPoolFromUrl,
  execSql,
  mergePasswordIntoMysqlUrl,
  readReplicaSlaveStatus,
  scalarString,
  type SlaveStatus,
} from "./mysql";
import type { Pool } from "mysql2/promise";
import { findLatestBackupS3Destination, type S3ClientConfig } from "./s3-latest-backup";
import {
  buildDesiredReplicationChannels,
  getClusterReady,
  getPxcSpec,
  patchReplicationChannels,
  verifyReplicationChannels,
} from "./replication";
import {
  createRestoreFromS3Destination,
  restoreInProgress,
  waitRestoreSucceededAndClusterReady,
} from "./restore";
import { K8S_PATCH_CONTENT_TYPE_OPTIONS } from "./k8s-patch-options";

type SourceEntry = { host: string; port: number; weight: number };

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

function randomIdent(prefix: string): string {
  const rnd = crypto.randomBytes(4).toString("hex");
  return `${prefix}_${rnd}`;
}

function sqlString(s: string): string {
  return `'${s.replace(/'/g, "''")}'`;
}

function slaveLooksHealthy(s: SlaveStatus, maxLagSeconds: number): boolean {
  if (s.ioRunning !== "Yes" || s.sqlRunning !== "Yes") return false;
  if (s.secondsBehind === null) return false;
  return s.secondsBehind <= maxLagSeconds;
}

function replicationBroken(s: SlaveStatus | null): boolean {
  if (!s) return true;
  if (s.ioRunning !== "Yes" || s.sqlRunning !== "Yes") return true;
  if (s.lastIoError || s.lastSqlError) return true;
  return false;
}

export async function runController(): Promise<void> {
  const PXC_NS = (() => {
    const fromEnv = process.env.PXC_NAMESPACE?.trim();
    if (fromEnv) return fromEnv;
    const nsPath = "/var/run/secrets/kubernetes.io/serviceaccount/namespace";
    try {
      return fs.readFileSync(nsPath, "utf8").trim();
    } catch {
      throw new Error(`PXC_NAMESPACE is not set and could not read pod namespace from ${nsPath}`);
    }
  })();

  const PXC_CLUSTER = envOptional("PXC_CLUSTER_NAME", "db");
  const isLocal = parseBoolEnv("IS_LOCAL", parseBoolEnv("isLocal", false));
  const CHANNEL_NAME = envOptional("REPLICATION_CHANNEL_NAME", "wookie_primary_to_replica");

  const allHosts = parseSourceHostList(env("SOURCE_HOSTS"));
  if (allHosts.length === 0) throw new Error("SOURCE_HOSTS must contain at least one hostname");
  const hostsForReplication = isLocal ? allHosts.slice(0, 1) : allHosts;

  const SOURCE_PORT = parseIntEnv("SOURCE_PORT", 3306);
  const SOURCE_WEIGHT = parseIntEnv("SOURCE_WEIGHT", 100);
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
  const S3_SECRET_NAME = env("S3_CREDENTIALS_SECRET");

  const MAX_LAG_SECONDS = parseIntEnv("MAX_REPLICATION_LAG_SECONDS", 5);
  const HEALTH_INTERVAL_SEC = parseIntEnv("HEALTHCHECK_INTERVAL_SECONDS", 60);
  const SELF_HEAL_FAILURE_THRESHOLD = parseIntEnv("SELF_HEAL_FAILURE_THRESHOLD", 3);

  const SOURCE_MYSQL_URL_BASE = env("SOURCE_MYSQL_URL");
  const REPLICA_MYSQL_URL = env("REPLICA_MYSQL_URL");
  const SOURCE_ROOT_DB_USERS_SECRET = envOptional("SOURCE_ROOT_DB_USERS_SECRET", "root-db-users");
  const SOURCE_MYSQL_ROOT_PASSWORD_KEY = envOptional("SOURCE_MYSQL_ROOT_PASSWORD_KEY", "mysql_root_source_pxc");
  const E2E_DB = assertMysqlIdentifier(envOptional("REPLICATION_E2E_DATABASE", "mysql"), "REPLICATION_E2E_DATABASE");

  const kc = new k8s.KubeConfig();
  kc.loadFromDefault();
  const core = kc.makeApiClient(k8s.CoreV1Api);
  const custom = kc.makeApiClient(k8s.CustomObjectsApi);
  const apps = kc.makeApiClient(k8s.AppsV1Api);

  async function loadSourceMysqlRootPasswordFromSecret(): Promise<string> {
    const sec = await core.readNamespacedSecret({ namespace: PXC_NS, name: SOURCE_ROOT_DB_USERS_SECRET });
    const data = sec.data as Record<string, string> | undefined;
    return decodeSecretData(data, SOURCE_MYSQL_ROOT_PASSWORD_KEY);
  }

  const sourceMysqlUrl = mergePasswordIntoMysqlUrl(
    SOURCE_MYSQL_URL_BASE,
    await loadSourceMysqlRootPasswordFromSecret()
  );

  let shuttingDown = false;
  const shutdown = () => {
    shuttingDown = true;
    log("SIGTERM/SIGINT received, shutting down gracefully");
  };
  process.on("SIGTERM", shutdown);
  process.on("SIGINT", shutdown);

  const sources: SourceEntry[] = hostsForReplication.map((host) => ({
    host,
    port: SOURCE_PORT,
    weight: SOURCE_WEIGHT,
  }));
  const desiredChannels = buildDesiredReplicationChannels({ channelName: CHANNEL_NAME, sources });

  log(
    `pxc-async-replica-controller starting ns=${PXC_NS} cluster=${PXC_CLUSTER} channel=${CHANNEL_NAME} ` +
      `SOURCE_HOSTS(${allHosts.length})=${allHosts.join(",")} replicationHosts(${hostsForReplication.length})=${hostsForReplication.join(",")} ` +
      `S3_ENDPOINT=${S3_ENDPOINT} S3_BUCKET=${S3_BUCKET} S3_PREFIX=${S3_PREFIX || "<none>"} S3_BACKUP_FOLDER_PREFIX=${S3_BACKUP_FOLDER_PREFIX}`
  );
  if (isLocal && allHosts.length > 1) {
    log(`IS_LOCAL=true: using first SOURCE_HOST only (${hostsForReplication[0]})`);
  }

  async function waitClusterReadyOrThrow(): Promise<void> {
    const deadline = Date.now() + READY_TIMEOUT_SEC * 1000;
    while (!shuttingDown && Date.now() < deadline) {
      const ok = await getClusterReady(custom, { pxcApiVersion: PXC_API_VERSION, ns: PXC_NS, cluster: PXC_CLUSTER });
      if (ok) return;
      const body = await getPxcSpec(custom, { pxcApiVersion: PXC_API_VERSION, ns: PXC_NS, cluster: PXC_CLUSTER });
      const status = body?.status as Obj | undefined;
      const state = typeof status?.state === "string" ? status.state : "";
      const msg = typeof status?.message === "string" ? status.message : "";
      log(`Waiting for cluster ready: state="${state}" message=${msg ? JSON.stringify(msg) : "none"}`);
      await sleep(POLL_MS);
    }
    throw new Error(`Timed out after ${READY_TIMEOUT_SEC}s waiting for cluster ${PXC_CLUSTER} ready`);
  }

  async function loadS3CfgFromSecret(): Promise<S3ClientConfig> {
    const sec = await core.readNamespacedSecret({ namespace: PXC_NS, name: S3_SECRET_NAME });
    const data = sec.data as Record<string, string> | undefined;

    let accessKeyId = "";
    let secretAccessKey = "";
    try {
      accessKeyId = decodeSecretData(data, "AWS_ACCESS_KEY_ID");
      secretAccessKey = decodeSecretData(data, "AWS_SECRET_ACCESS_KEY");
    } catch {
      accessKeyId = decodeSecretData(data, "access_key");
      secretAccessKey = decodeSecretData(data, "secret_key");
    }

    return {
      endpoint: S3_ENDPOINT,
      region: S3_REGION,
      forcePathStyle: S3_FORCE_PATH_STYLE,
      accessKeyId,
      secretAccessKey,
    };
  }

  async function restoreFromLatestSeaweedBackup(): Promise<void> {
    const s3cfg = await loadS3CfgFromSecret();
    const listPrefix = `${S3_PREFIX}${S3_BACKUP_FOLDER_PREFIX}`;
    const latest = await findLatestBackupS3Destination({
      cfg: s3cfg,
      bucket: S3_BUCKET,
      prefix: listPrefix.length > 0 ? listPrefix : undefined,
    });
    log(`Selected latest backup destination=${latest.destination} (chosenPrefix=${latest.chosenPrefix}, listPrefix=${JSON.stringify(listPrefix)})`);

    if (await restoreInProgress(custom, { pxcApiVersion: PXC_API_VERSION, ns: PXC_NS })) {
      log("Restore already in progress in this namespace; waiting for cluster ready (external restore)");
      await waitClusterReadyOrThrow();
      return;
    }

    const restoreName = `async-replica-restore-${new Date().toISOString().replace(/[-:.TZ]/g, "").slice(0, 14)}`;

    await createRestoreFromS3Destination(custom, {
      pxcApiVersion: PXC_API_VERSION,
      ns: PXC_NS,
      cluster: PXC_CLUSTER,
      restoreName,
      destination: latest.destination,
      s3: {
        credentialsSecret: S3_SECRET_NAME,
        region: S3_REGION,
        endpointUrl: S3_ENDPOINT,
        forcePathStyle: S3_FORCE_PATH_STYLE,
      },
    });

    const result = await waitRestoreSucceededAndClusterReady({
      custom,
      pxcApiVersion: PXC_API_VERSION,
      ns: PXC_NS,
      cluster: PXC_CLUSTER,
      restoreName,
      timeoutSeconds: RESTORE_TIMEOUT_SEC,
      pollMs: POLL_MS,
      isShuttingDown: () => shuttingDown,
    });

    if (result !== "succeeded") {
      throw new Error(`Restore did not succeed (result=${result}, restore=${restoreName})`);
    }
  }

  async function applyReplicationIfNeeded(): Promise<void> {
    const initial = await getPxcSpec(custom, { pxcApiVersion: PXC_API_VERSION, ns: PXC_NS, cluster: PXC_CLUSTER });
    const initialSpec = initial?.spec as Obj | undefined;
    const initialPxc = initialSpec?.pxc as Obj | undefined;
    const existing = initialPxc?.replicationChannels;

    const already = await verifyReplicationChannels(custom, {
      pxcApiVersion: PXC_API_VERSION,
      ns: PXC_NS,
      cluster: PXC_CLUSTER,
      desired: desiredChannels,
    });
    if (already) {
      log("replicationChannels already match desired; skipping patch");
      return;
    }

    log(`Current replicationChannels: ${JSON.stringify(existing)}`);
    await patchReplicationChannels(custom, {
      pxcApiVersion: PXC_API_VERSION,
      ns: PXC_NS,
      cluster: PXC_CLUSTER,
      channels: desiredChannels,
    });
    await sleep(3000);

    if (!(await verifyReplicationChannels(custom, { pxcApiVersion: PXC_API_VERSION, ns: PXC_NS, cluster: PXC_CLUSTER, desired: desiredChannels }))) {
      throw new Error("VERIFY FAILED: replicationChannels do not match desired after patch");
    }
  }

  async function waitMysqlReplicationHealthy(pool: Pool): Promise<void> {
    const deadline = Date.now() + READY_TIMEOUT_SEC * 1000;
    while (!shuttingDown && Date.now() < deadline) {
      const s = await readReplicaSlaveStatus(pool);
      if (!s) {
        log("Replication check: SHOW SLAVE STATUS returned no rows (replication not configured yet?)");
      } else {
        log(
          `Replication check: IO=${s.ioRunning} SQL=${s.sqlRunning} lag=${s.secondsBehind ?? "null"}s ` +
            `ioErr=${JSON.stringify(s.lastIoError)} sqlErr=${JSON.stringify(s.lastSqlError)}`
        );
        if (slaveLooksHealthy(s, MAX_LAG_SECONDS)) return;
      }
      await sleep(POLL_MS);
    }
    throw new Error(`Timed out after ${READY_TIMEOUT_SEC}s waiting for replication lag<=${MAX_LAG_SECONDS}s`);
  }

  async function runOneShotRowReplicationTest(): Promise<void> {
    const sourcePool = createMysqlPoolFromUrl(sourceMysqlUrl);
    const replicaPool = createMysqlPoolFromUrl(REPLICA_MYSQL_URL);

    const table = randomIdent("async_rep_e2e");
    const fqtn = `\`${E2E_DB}\`.\`${table}\``;

    try {
      log(`E2E: creating table ${fqtn} on SOURCE and inserting a row`);
      await execSql(sourcePool, `CREATE DATABASE IF NOT EXISTS \`${E2E_DB}\``);
      await execSql(sourcePool, `CREATE TABLE ${fqtn} (id INT PRIMARY KEY, note VARCHAR(128))`);
      const note = `hello-${Date.now()}`;
      await execSql(sourcePool, `INSERT INTO ${fqtn} (id, note) VALUES (1, ${sqlString(note)})`);

      log("E2E: waiting for row to appear on REPLICA");
      const deadline = Date.now() + READY_TIMEOUT_SEC * 1000;
      let ok = false;
      while (!shuttingDown && Date.now() < deadline) {
        const got = await scalarString(replicaPool, `SELECT note FROM ${fqtn} WHERE id=1`);
        if (got === note) {
          ok = true;
          break;
        }
        await sleep(500);
      }
      if (!ok) {
        const got = await scalarString(replicaPool, `SELECT note FROM ${fqtn} WHERE id=1`);
        throw new Error(`E2E FAILED: expected replicated note=${JSON.stringify(note)} got=${JSON.stringify(got)}`);
      }
      log("E2E: replicated row verified on REPLICA");

      log(`E2E: dropping table ${fqtn} on SOURCE`);
      await execSql(sourcePool, `DROP TABLE IF EXISTS ${fqtn}`);

      log("E2E: waiting for DROP to replicate to REPLICA");
      const deadline2 = Date.now() + READY_TIMEOUT_SEC * 1000;
      while (!shuttingDown && Date.now() < deadline2) {
        const cnt = await scalarString(
          replicaPool,
          `SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${E2E_DB.replace(/'/g, "''")}' AND table_name='${table.replace(/'/g, "''")}'`
        );
        if (cnt === "0") {
          log("E2E: drop replicated; cleanup verified");
          return;
        }
        await sleep(500);
      }

      const cnt2 = await scalarString(
        replicaPool,
        `SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${E2E_DB.replace(/'/g, "''")}' AND table_name='${table.replace(/'/g, "''")}'`
      );
      throw new Error(`E2E FAILED: expected table gone on replica, information_schema count=${cnt2}`);
    } finally {
      await sourcePool.end().catch(() => {});
      await replicaPool.end().catch(() => {});
    }
  }

  async function tryRestartWorkloadByLabels(args: { appLabel: string; component: string; object: "statefulset" | "deployment" }): Promise<boolean> {
    const labelSelector = `app.kubernetes.io/name=${args.appLabel},app.kubernetes.io/component=${args.component}`;
    try {
      if (args.object === "statefulset") {
        const resp = await apps.listNamespacedStatefulSet({ namespace: PXC_NS, labelSelector });
        const items = resp.items ?? [];
        if (items.length === 0) {
          log(`SELF-HEAL: no StatefulSet matched selector ${labelSelector}`);
          return false;
        }
        const name = items[0].metadata?.name;
        if (!name) return false;
        log(`SELF-HEAL: restarting StatefulSet/${name} (${labelSelector})`);
        const patch = { spec: { template: { metadata: { annotations: { "pxc-async-replica/restartedAt": new Date().toISOString() } } } } };
        await apps.patchNamespacedStatefulSet(
          { namespace: PXC_NS, name, body: patch },
          K8S_PATCH_CONTENT_TYPE_OPTIONS
        );
        return true;
      }

      const resp = await apps.listNamespacedDeployment({ namespace: PXC_NS, labelSelector });
      const items = resp.items ?? [];
      if (items.length === 0) {
        log(`SELF-HEAL: no Deployment matched selector ${labelSelector}`);
        return false;
      }
      const name = items[0].metadata?.name;
      if (!name) return false;
      log(`SELF-HEAL: restarting Deployment/${name} (${labelSelector})`);
      const patch = { spec: { template: { metadata: { annotations: { "pxc-async-replica/restartedAt": new Date().toISOString() } } } } };
      await apps.patchNamespacedDeployment(
        { namespace: PXC_NS, name, body: patch },
        K8S_PATCH_CONTENT_TYPE_OPTIONS
      );
      return true;
    } catch (e: unknown) {
      log(`SELF-HEAL: restart failed: ${formatK8sError(e)}`);
      return false;
    }
  }

  async function selfHealReplication(args: { replicaPool: Pool; attempt: number }): Promise<void> {
    log(`SELF-HEAL: attempt ${args.attempt} starting (threshold=${SELF_HEAL_FAILURE_THRESHOLD})`);

    // 1) Re-assert desired replicationChannels (covers drift / partial application)
    try {
      log("SELF-HEAL: re-applying replicationChannels (merge patch)");
      await patchReplicationChannels(custom, {
        pxcApiVersion: PXC_API_VERSION,
        ns: PXC_NS,
        cluster: PXC_CLUSTER,
        channels: desiredChannels,
      });
      await sleep(3000);
      await verifyReplicationChannels(custom, { pxcApiVersion: PXC_API_VERSION, ns: PXC_NS, cluster: PXC_CLUSTER, desired: desiredChannels });
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
      log("SELF-HEAL: escalating to full restore-from-latest-backup");
      await restoreFromLatestSeaweedBackup();
      await waitClusterReadyOrThrow();
      await applyReplicationIfNeeded();
      await waitMysqlReplicationHealthy(args.replicaPool);
    }
  }

  // --- Main orchestration ---
  const replicaPool = createMysqlPoolFromUrl(REPLICA_MYSQL_URL);

  try {
    log("Phase A: restore latest backup from Seaweed S3 (if needed)");
    await restoreFromLatestSeaweedBackup();

    log("Phase B: wait for PXC cluster ready after restore/bootstrap");
    await waitClusterReadyOrThrow();

    log("Phase C: apply replicationChannels after restore + ready");
    await applyReplicationIfNeeded();

    log(`Phase D: wait for async replication health (lag<=${MAX_LAG_SECONDS}s)`);
    await waitMysqlReplicationHealthy(replicaPool);

    log("Phase E: one-shot row-level replication test (source->replica->drop)");
    await runOneShotRowReplicationTest();

    log(`Phase F: periodic replication health checks every ${HEALTH_INTERVAL_SEC}s`);
    let failStreak = 0;

    while (!shuttingDown) {
      const s = await readReplicaSlaveStatus(replicaPool);
      if (!s) {
        log("HEALTH: SHOW SLAVE STATUS returned no rows");
      } else {
        log(
          `HEALTH: IO=${s.ioRunning} SQL=${s.sqlRunning} lag=${s.secondsBehind ?? "null"}s ` +
            `ioErr=${JSON.stringify(s.lastIoError)} sqlErr=${JSON.stringify(s.lastSqlError)}`
        );
      }

      const healthy = !!s && slaveLooksHealthy(s, MAX_LAG_SECONDS) && !replicationBroken(s);
      if (healthy) {
        failStreak = 0;
      } else {
        failStreak += 1;
        log(`HEALTH: unhealthy (failStreak=${failStreak})`);
        await selfHealReplication({ replicaPool, attempt: failStreak });
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
}
