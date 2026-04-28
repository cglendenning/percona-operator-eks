import * as fs from "fs";
import * as k8s from "@kubernetes/client-node";
import * as readline from "readline";
import {
  deepReplace,
  parseRules,
  ruleUsesPmmTemplate,
  sha256Hex,
  syncIncremental,
  type JsonObj,
} from "./alertSync";
import { logLine } from "./log";
import { createPmmClient } from "./pmmClient";

function envOptional(name: string, defaultValue: string): string {
  return process.env[name]?.trim() || defaultValue;
}

function parseBoolEnv(name: string, defaultValue: boolean): boolean {
  const raw = process.env[name]?.trim().toLowerCase();
  if (!raw) return defaultValue;
  return raw === "1" || raw === "true" || raw === "yes";
}

function parseIntEnv(name: string, defaultValue: number): number {
  const raw = process.env[name]?.trim();
  if (!raw) return defaultValue;
  const n = parseInt(raw, 10);
  return Number.isFinite(n) ? n : defaultValue;
}

function readNamespaceFromServiceAccount(): string {
  const nsFile = "/var/run/secrets/kubernetes.io/serviceaccount/namespace";
  return fs.readFileSync(nsFile, "utf8").trim();
}

async function promptIfMissing(value: string | undefined, promptText: string): Promise<string> {
  if (value?.trim()) return value.trim();
  if (!process.stdin.isTTY) throw new Error(`Missing ${promptText} and no TTY available for prompt`);
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
  try {
    const answer = await new Promise<string>((resolve) => {
      rl.question(`${promptText}: `, (input) => resolve(input));
    });
    if (!answer.trim()) throw new Error(`${promptText} cannot be empty`);
    return answer.trim();
  } finally {
    rl.close();
  }
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

export async function runController(): Promise<void> {
  const configMapName = envOptional("ALERT_RULES_CONFIGMAP", "pxc-pmm-alert-rules");
  const configMapKey = envOptional("ALERT_RULES_KEY", "rules.json");
  const namespace = process.env.ALERT_RULES_NAMESPACE?.trim() || readNamespaceFromServiceAccount();
  const pmmBaseUrl = envOptional(
    "PMM_URL",
    "https://monitoring-service.pmm.svc.cluster.local"
  ).replace(/\/+$/, "");
  const ruleGroupName = envOptional("RULE_GROUP_NAME", "template");
  /** Backward-compat cleanup group name for old batched expr mode. */
  const exprRuleBatchGroupName = envOptional("EXPR_RULE_BATCH_GROUP", "expression");
  const syncIntervalMs = parseIntEnv("SYNC_INTERVAL_MS", 60_000);
  if (!Number.isFinite(syncIntervalMs) || syncIntervalMs < 5000) throw new Error("SYNC_INTERVAL_MS must be >= 5000");
  const requestTimeoutMs = parseIntEnv("PMM_REQUEST_TIMEOUT_MS", 15_000);
  const insecureTls = parseBoolEnv("PMM_INSECURE_TLS", true);

  let stopping = false;
  const onStop = () => {
    stopping = true;
  };
  process.on("SIGTERM", onStop);
  process.on("SIGINT", onStop);

  const kc = new k8s.KubeConfig();
  kc.loadFromDefault();
  const core = kc.makeApiClient(k8s.CoreV1Api);

  try {
    const user = await promptIfMissing(process.env.PMM_USER ?? process.env.GRAFANA_USER, "PMM_USER");
    const password = await promptIfMissing(process.env.PMM_PASSWORD ?? process.env.GRAFANA_PASSWORD, "PMM_PASSWORD");

    const pmm = createPmmClient({
      baseUrl: pmmBaseUrl,
      user,
      password,
      timeoutMs: requestTimeoutMs,
      insecureTls,
    });

    /** Re-resolve folder/datasource UIDs only when ConfigMap bytes change (`rulesDigest`). */
    let uidCache: { digest: string; folderUid: string; datasourceUid: string } | undefined;

    logLine(
      `pxc-pmm-alerts-controller started pmmUrl=${pmmBaseUrl} ns=${namespace} cm=${configMapName}/${configMapKey} ` +
        `ruleGroup=${ruleGroupName} exprBatchGroup=${exprRuleBatchGroupName} syncIntervalMs=${syncIntervalMs} ` +
        `requestTimeoutMs=${requestTimeoutMs} insecureTls=${insecureTls}`
    );

    while (!stopping) {
      const cycleStart = Date.now();
      try {
        const cfg = await core.readNamespacedConfigMap({ name: configMapName, namespace });
        const rawRulesPeek = cfg.data?.[configMapKey];
        if (!rawRulesPeek) throw new Error(`ConfigMap ${namespace}/${configMapName} missing key ${configMapKey}`);
        const rulesDigest = sha256Hex(rawRulesPeek);

        let folderUid: string;
        let datasourceUid: string;
        if (uidCache?.digest === rulesDigest) {
          folderUid = uidCache.folderUid;
          datasourceUid = uidCache.datasourceUid;
          logLine(`sync: using cached MySQL folder / datasource UIDs (ConfigMap digest unchanged)`);
        } else {
          logLine("sync: resolving MySQL folder UID…");
          folderUid = await pmm.resolveMySqlFolderUid();
          logLine(`sync: MySQL folder uid=${folderUid}`);
          logLine("sync: resolving Grafana datasource UID…");
          datasourceUid = await pmm.resolveDatasourceUid();
          logLine(`sync: datasource uid=${datasourceUid}`);
          uidCache = { digest: rulesDigest, folderUid, datasourceUid };
        }

        const rawRules = rawRulesPeek;

        const desiredRules = parseRules(rawRules).map((rule) =>
          deepReplace(rule, {
            "__MYSQL_FOLDER_UID__": folderUid,
            "${MYSQL_FOLDER_UID}": folderUid,
          })
        ) as JsonObj[];

        const templateRules = desiredRules.filter((r) => ruleUsesPmmTemplate(r));
        const exprRules = desiredRules.filter((r) => !ruleUsesPmmTemplate(r));

        const applied = await syncIncremental({
          pmm,
          folderUid,
          datasourceUid,
          ruleGroupName,
          exprRuleBatchGroupName,
          templateRules,
          exprRules,
        });

        logLine(
          applied === 0
            ? `sync: no changes needed (${Date.now() - cycleStart}ms digest=${rulesDigest.slice(0, 12)}…)`
            : `sync: applied ${applied} rule operations in ${Date.now() - cycleStart}ms digest=${rulesDigest.slice(0, 12)}…`
        );
      } catch (err: unknown) {
        const message = err instanceof Error ? err.message : String(err);
        logLine(`sync iteration failed: ${message}`);
      }
      await sleep(syncIntervalMs);
    }
  } finally {
    process.off("SIGTERM", onStop);
    process.off("SIGINT", onStop);
  }
}
