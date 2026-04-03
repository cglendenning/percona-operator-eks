import * as fs from "fs";
import * as k8s from "@kubernetes/client-node";

type Obj = Record<string, unknown>;

function env(name: string): string {
  const v = process.env[name];
  if (!v) throw new Error(`Missing required env var: ${name}`);
  return v;
}

function envOptional(name: string, defaultValue: string): string {
  return process.env[name] ?? defaultValue;
}

function getCurrentNamespace(): string {
  const fromEnv = process.env.PXC_NAMESPACE?.trim();
  if (fromEnv) return fromEnv;
  const nsPath = "/var/run/secrets/kubernetes.io/serviceaccount/namespace";
  try {
    return fs.readFileSync(nsPath, "utf8").trim();
  } catch {
    throw new Error(
      `PXC_NAMESPACE is not set and could not read pod namespace from ${nsPath}`
    );
  }
}

function parseIsLocal(): boolean {
  const raw = process.env.IS_LOCAL ?? process.env.isLocal;
  const v = raw?.trim().toLowerCase();
  return v === "true" || v === "1" || v === "yes";
}

function parseSourceHostList(raw: string): string[] {
  return raw
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean);
}

function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}

function isoNow(): string {
  return new Date().toISOString();
}

function log(msg: string): void {
  process.stdout.write(`[${isoNow()}] ${msg}\n`);
}

function asString(x: unknown): string {
  return typeof x === "string" ? x : "";
}

function parseIntEnv(name: string, defaultValue: number): number {
  const raw = process.env[name];
  if (!raw) return defaultValue;
  const n = parseInt(raw, 10);
  return Number.isFinite(n) ? n : defaultValue;
}

type SourceEntry = { host: string; port: number; weight: number };

function buildDesiredChannels(
  channelName: string,
  sources: SourceEntry[]
): Obj[] {
  return [
    {
      name: channelName,
      isSource: false,
      sourcesList: sources.map((s) => ({
        host: s.host,
        port: s.port,
        weight: s.weight,
      })),
    },
  ];
}

function normalizeChannels(ch: unknown): string {
  if (!Array.isArray(ch)) return "[]";
  const arr = ch as Obj[];
  const sorted: Obj[] = [...arr].map((c: Obj) => {
    const sources = Array.isArray(c.sourcesList) ? [...(c.sourcesList as Obj[])] : [];
    sources.sort((a, b) =>
      asString(a.host).localeCompare(asString(b.host))
    );
    return { ...c, sourcesList: sources } as Obj;
  });
  sorted.sort((a, b) => asString(a.name).localeCompare(asString(b.name)));
  return JSON.stringify(sorted);
}

function channelsMatchSpec(actual: unknown, expected: Obj[]): boolean {
  return normalizeChannels(actual) === normalizeChannels(expected);
}

function formatK8sError(err: unknown): string {
  const e = err as {
    message?: string;
    statusCode?: number;
    response?: { statusCode?: number; body?: { message?: string; reason?: string } };
  };
  const status = e?.statusCode ?? e?.response?.statusCode;
  const body = e?.response?.body;
  const k8sMessage = body?.message;
  const reason = body?.reason;
  const parts = [String(e?.message ?? err)];
  if (status) parts.push(`status=${status}`);
  if (reason) parts.push(`reason=${reason}`);
  if (k8sMessage) parts.push(`k8sMessage=${k8sMessage}`);
  return parts.join(" ");
}

async function main(): Promise<void> {
  const PXC_NS = getCurrentNamespace();
  const PXC_CLUSTER = envOptional("PXC_CLUSTER_NAME", "db");
  const isLocal = parseIsLocal();
  const CHANNEL_NAME = envOptional("REPLICATION_CHANNEL_NAME", "wookie_primary_to_replica");

  const allHosts = parseSourceHostList(env("SOURCE_HOSTS"));
  if (allHosts.length === 0) {
    throw new Error("SOURCE_HOSTS must contain at least one hostname");
  }

  const hostsForReplication = isLocal ? allHosts.slice(0, 1) : allHosts;

  const SOURCE_PORT = parseIntEnv("SOURCE_PORT", 3306);
  const SOURCE_WEIGHT = parseIntEnv("SOURCE_WEIGHT", 100);
  const PXC_API_VERSION = envOptional("PXC_API_VERSION", "v1");
  const READY_TIMEOUT_SEC = parseIntEnv("READY_TIMEOUT_SECONDS", 3600);
  const POLL_MS = parseIntEnv("POLL_INTERVAL_MS", 10000);
  const IDLE_AFTER_SUCCESS_SEC = parseIntEnv("IDLE_AFTER_SUCCESS_SECONDS", 86400);

  const sources: SourceEntry[] = hostsForReplication.map((host) => ({
    host,
    port: SOURCE_PORT,
    weight: SOURCE_WEIGHT,
  }));
  const desiredChannels = buildDesiredChannels(CHANNEL_NAME, sources);

  log(
    `pxc-async-replica-controller starting ns=${PXC_NS} cluster=${PXC_CLUSTER} IS_LOCAL=${isLocal} channel=${CHANNEL_NAME} SOURCE_HOSTS(${allHosts.length})=${allHosts.join(",")} replicationHosts(${hostsForReplication.length})=${hostsForReplication.join(",")} port=${SOURCE_PORT}`
  );
  if (isLocal && allHosts.length > 1) {
    log(
      `IS_LOCAL=true: applying replication for the first hostname only (${hostsForReplication[0]}); ignoring ${allHosts.length - 1} additional host(s)`
    );
  }

  const kc = new k8s.KubeConfig();
  kc.loadFromDefault();
  const custom = kc.makeApiClient(k8s.CustomObjectsApi);

  let shuttingDown = false;
  const shutdown = () => {
    shuttingDown = true;
    log("SIGTERM received, exiting");
  };
  process.on("SIGTERM", shutdown);
  process.on("SIGINT", shutdown);

  async function getCluster(): Promise<Obj | null> {
    try {
      const resp = await custom.getNamespacedCustomObject(
        "pxc.percona.com",
        PXC_API_VERSION,
        PXC_NS,
        "perconaxtradbclusters",
        PXC_CLUSTER
      );
      return (resp.body ?? null) as Obj | null;
    } catch (e: unknown) {
      log(`get cluster failed: ${formatK8sError(e)}`);
      return null;
    }
  }

  async function waitReady(): Promise<boolean> {
    const deadline = Date.now() + READY_TIMEOUT_SEC * 1000;
    while (!shuttingDown && Date.now() < deadline) {
      const body = await getCluster();
      if (body) {
        const status = body.status as Obj | undefined;
        const state = asString(status?.state);
        const msg = asString(status?.message);
        log(`PXC cluster ${PXC_CLUSTER} state="${state}" message=${msg ? JSON.stringify(msg) : "none"}`);
        if (state === "ready") return true;
      }
      await sleep(POLL_MS);
    }
    log(`Timed out after ${READY_TIMEOUT_SEC}s waiting for cluster ${PXC_CLUSTER} ready in ns=${PXC_NS}`);
    return false;
  }

  async function patchReplicationChannels(channels: Obj[]): Promise<void> {
    const patchBody = {
      spec: {
        pxc: {
          replicationChannels: channels,
        },
      },
    };
    const ch0 = channels[0] as Obj | undefined;
    const nSources = Array.isArray(ch0?.sourcesList) ? (ch0.sourcesList as Obj[]).length : 0;
    log(`Patching ${PXC_CLUSTER} with replicationChannels (${nSources} source host(s) in channel)`);
    await custom.patchNamespacedCustomObject(
      "pxc.percona.com",
      PXC_API_VERSION,
      PXC_NS,
      "perconaxtradbclusters",
      PXC_CLUSTER,
      patchBody,
      undefined,
      undefined,
      undefined,
      { headers: { "Content-Type": "application/merge-patch+json" } }
    );
    log("Merge patch applied successfully");
  }

  async function verifyChannels(): Promise<boolean> {
    const body = await getCluster();
    if (!body) {
      log("VERIFY FAILED: could not read cluster");
      return false;
    }
    const spec = body.spec as Obj | undefined;
    const pxc = spec?.pxc as Obj | undefined;
    const actual = pxc?.replicationChannels;
    const ok = channelsMatchSpec(actual, desiredChannels as Obj[]);
    if (ok) {
      log(`VERIFY OK: replicationChannels match desired (${normalizeChannels(actual)})`);
    } else {
      log(
        `VERIFY FAILED: expected=${normalizeChannels(desiredChannels)} actual=${normalizeChannels(actual)}`
      );
    }
    return ok;
  }

  if (!(await waitReady())) {
    process.exit(1);
  }

  const initial = await getCluster();
  const initialSpec = initial?.spec as Obj | undefined;
  const initialPxc = initialSpec?.pxc as Obj | undefined;
  const existing = initialPxc?.replicationChannels;
  if (channelsMatchSpec(existing, desiredChannels as Obj[])) {
    log("replicationChannels already match desired; skipping patch");
  } else {
    log(`Current replicationChannels: ${normalizeChannels(existing)}`);
    try {
      await patchReplicationChannels(desiredChannels as Obj[]);
    } catch (e: unknown) {
      log(`PATCH FAILED: ${formatK8sError(e)}`);
      process.exit(1);
    }
    await sleep(3000);
  }

  if (!(await verifyChannels())) {
    process.exit(1);
  }

  log("pxc-async-replica-controller finished successfully; sleeping to keep pod alive for log inspection");
  let remainingSec = IDLE_AFTER_SUCCESS_SEC;
  while (!shuttingDown && remainingSec > 0) {
    const step = Math.min(remainingSec, 60);
    await sleep(step * 1000);
    remainingSec -= step;
  }
  process.exit(0);
}

main().catch((e: unknown) => {
  log(`FATAL: ${formatK8sError(e)}`);
  process.exit(1);
});
