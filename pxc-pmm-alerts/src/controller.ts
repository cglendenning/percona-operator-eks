import * as crypto from "crypto";
import * as fs from "fs";
import * as http from "http";
import * as https from "https";
import * as readline from "readline";
import * as k8s from "@kubernetes/client-node";
import { URL } from "url";

type JsonValue = null | boolean | number | string | JsonValue[] | { [key: string]: JsonValue };
type JsonObj = { [key: string]: JsonValue };

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

function logLine(message: string): void {
  console.log(`${new Date().toISOString()} ${message}`);
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

async function pmmRequest<T>(args: {
  baseUrl: string;
  user: string;
  password: string;
  path: string;
  method?: string;
  body?: unknown;
  timeoutMs: number;
  insecureTls: boolean;
  /** If set, these HTTP codes are treated as success (e.g. 404 on delete-if-absent). */
  okStatuses?: Set<number>;
}): Promise<T> {
  const fullUrl = `${args.baseUrl}${args.path}`;
  const url = new URL(fullUrl);
  const isHttps = url.protocol === "https:";
  const authHeader = `Basic ${Buffer.from(`${args.user}:${args.password}`).toString("base64")}`;
  const payload = args.body !== undefined ? JSON.stringify(args.body) : undefined;

  return await new Promise<T>((resolve, reject) => {
    const opts: http.RequestOptions | https.RequestOptions = {
      method: args.method ?? "GET",
      hostname: url.hostname,
      port: url.port || (isHttps ? "443" : "80"),
      path: `${url.pathname}${url.search}`,
      headers: {
        Authorization: authHeader,
        Accept: "application/json",
        ...(payload ? { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(payload) } : {}),
      },
      timeout: args.timeoutMs,
      ...(isHttps ? { rejectUnauthorized: !args.insecureTls } : {}),
    };

    const lib = isHttps ? https : http;
    const req = lib.request(opts, (res) => {
      const chunks: Buffer[] = [];
      res.on("data", (d) => chunks.push(d as Buffer));
      res.on("end", () => {
        const status = res.statusCode ?? 0;
        const rawBody = Buffer.concat(chunks).toString("utf8").trim();
        const okExtra = args.okStatuses?.has(status);
        if ((status < 200 || status >= 300) && !okExtra) {
          reject(new Error(`PMM API ${args.method ?? "GET"} ${args.path} failed: ${status} ${rawBody}`));
          return;
        }
        if (status === 204 || rawBody.length === 0) {
          resolve({} as T);
          return;
        }
        try {
          resolve(JSON.parse(rawBody) as T);
        } catch (e: unknown) {
          if (okExtra && status >= 400) {
            resolve({} as T);
            return;
          }
          reject(new Error(`PMM API ${args.path}: invalid JSON: ${String(e)} body=${rawBody.slice(0, 500)}`));
        }
      });
    });

    req.on("error", reject);
    req.on("timeout", () => {
      req.destroy();
      reject(new Error(`PMM API request timed out after ${args.timeoutMs}ms: ${args.method ?? "GET"} ${args.path}`));
    });

    if (payload) req.write(payload);
    req.end();
  });
}

async function resolveDatasourceUid(
  baseUrl: string,
  user: string,
  password: string,
  req: { timeoutMs: number; insecureTls: boolean }
): Promise<string> {
  type Datasource = { uid?: string; type?: string; isDefault?: boolean };
  const datasources = await pmmRequest<Datasource[]>({
    baseUrl,
    user,
    password,
    path: "/graph/api/datasources",
    timeoutMs: req.timeoutMs,
    insecureTls: req.insecureTls,
  });
  const preferred =
    datasources.find((ds) => (ds.type === "prometheus" || ds.type === "victoriametrics") && ds.uid) ||
    datasources.find((ds) => ds.isDefault && ds.uid) ||
    datasources.find((ds) => !!ds.uid);
  if (!preferred?.uid) throw new Error("Could not resolve Grafana datasource UID");
  return preferred.uid;
}

async function resolveMySqlFolderUid(
  baseUrl: string,
  user: string,
  password: string,
  req: { timeoutMs: number; insecureTls: boolean }
): Promise<string> {
  type Folder = { uid?: string; title?: string };
  const folders = await pmmRequest<Folder[]>({
    baseUrl,
    user,
    password,
    path: "/graph/api/folders",
    timeoutMs: req.timeoutMs,
    insecureTls: req.insecureTls,
  });
  const mysqlFolder = folders.find((folder) => folder.title === "MySQL");
  if (!mysqlFolder?.uid) throw new Error("Could not find Grafana folder with title \"MySQL\"");
  return mysqlFolder.uid;
}

function parseRules(jsonPayload: string): JsonObj[] {
  const parsed = JSON.parse(jsonPayload) as JsonValue;
  if (!Array.isArray(parsed) || parsed.length === 0) {
    throw new Error("ConfigMap value must be a non-empty JSON array");
  }
  const rules = parsed.filter((x): x is JsonObj => !!x && typeof x === "object" && !Array.isArray(x));
  if (rules.length !== parsed.length) throw new Error("Every alert payload must be a JSON object");
  return rules;
}

function deepReplace(value: JsonValue, replacements: Record<string, string>): JsonValue {
  if (typeof value === "string") {
    return Object.entries(replacements).reduce((acc, [token, replacement]) => acc.split(token).join(replacement), value);
  }
  if (Array.isArray(value)) return value.map((v) => deepReplace(v, replacements));
  if (value && typeof value === "object") {
    const out: JsonObj = {};
    for (const [k, v] of Object.entries(value)) out[k] = deepReplace(v, replacements);
    return out;
  }
  return value;
}

function getRuleName(rule: JsonObj): string {
  const candidates = [rule.name, rule.alert_name, rule.title];
  for (const c of candidates) {
    if (typeof c === "string" && c.trim()) return c.trim();
  }
  throw new Error(`Rule missing name/title field: ${JSON.stringify(rule)}`);
}

function ruleUsesPmmTemplate(rule: JsonObj): boolean {
  const t = rule.template_name;
  return typeof t === "string" && t.trim().length > 0;
}

/** One `rules[]` entry for the Grafana ruler API (see `projects/pmm/default.nix`). */
function buildGrafanaExprRuleEntry(rule: JsonObj, datasourceUid: string): JsonObj {
  const name = getRuleName(rule);
  const expr = typeof rule.expr === "string" ? rule.expr : "";
  if (!expr.trim()) throw new Error(`Expr rule "${name}" is missing expr`);
  const forDur = typeof rule.for === "string" ? rule.for : "60s";
  const noData = typeof rule.no_data_state === "string" ? rule.no_data_state : "OK";
  const rawLabels =
    rule.custom_labels && typeof rule.custom_labels === "object" && !Array.isArray(rule.custom_labels)
      ? (rule.custom_labels as JsonObj)
      : {};
  const labels: JsonObj = {};
  for (const [k, v] of Object.entries(rawLabels)) {
    if (v === null || v === undefined) continue;
    labels[k] = typeof v === "string" ? v : String(v);
  }

  // PostableGrafanaRule: for / labels / annotations are siblings of grafana_alert (Grafana/PMM v3).
  return {
    grafana_alert: {
      title: name,
      condition: "B",
      data: [
        {
          refId: "A",
          queryType: "",
          relativeTimeRange: { from: 600, to: 0 },
          datasourceUid,
          model: { expr, refId: "A", legendFormat: "", instant: false, range: true },
        },
        {
          refId: "B",
          queryType: "",
          relativeTimeRange: { from: 0, to: 0 },
          datasourceUid: "__expr__",
          model: {
            type: "classic_conditions",
            refId: "B",
            conditions: [
              {
                evaluator: { params: [0], type: "gt" },
                operator: { type: "and" },
                query: { params: ["A"] },
                reducer: { params: [], type: "last" },
              },
            ],
          },
        },
      ],
      no_data_state: noData,
      exec_err_state: "Alerting",
    },
    for: forDur,
    labels,
    annotations: {},
  };
}

/** Single POST with N rules: avoids repeated ruler POSTs to the same folder (only the last group survived in practice). */
function buildBatchedExprRulerGroup(exprRules: JsonObj[], datasourceUid: string, batchGroupName: string): JsonObj {
  if (exprRules.length === 0) throw new Error("buildBatchedExprRulerGroup: no expr rules");
  return {
    name: batchGroupName,
    interval: "1m",
    rules: exprRules.map((r) => buildGrafanaExprRuleEntry(r, datasourceUid)),
  };
}

async function postBatchedExprRulerGroup(args: {
  baseUrl: string;
  user: string;
  password: string;
  folderUid: string;
  body: JsonObj;
  timeoutMs: number;
  insecureTls: boolean;
}): Promise<void> {
  await pmmRequest({
    baseUrl: args.baseUrl,
    user: args.user,
    password: args.password,
    method: "POST",
    path: `/graph/api/ruler/grafana/api/v1/rules/${args.folderUid}`,
    body: args.body,
    timeoutMs: args.timeoutMs,
    insecureTls: args.insecureTls,
  });
}

/** PMM Server does not expose a working GET /v1/alerting/rules list (returns 501). Recreate uses Grafana ruler DELETE group then POST each rule. */
async function deleteRulerRuleGroup(args: {
  baseUrl: string;
  user: string;
  password: string;
  folderUid: string;
  ruleGroupName: string;
  timeoutMs: number;
  insecureTls: boolean;
}): Promise<void> {
  const encGroup = encodeURIComponent(args.ruleGroupName);
  await pmmRequest({
    baseUrl: args.baseUrl,
    user: args.user,
    password: args.password,
    method: "DELETE",
    path: `/graph/api/ruler/grafana/api/v1/rules/${args.folderUid}/${encGroup}`,
    timeoutMs: args.timeoutMs,
    insecureTls: args.insecureTls,
    okStatuses: new Set([404, 202, 200]),
  });
}

async function createRule(
  baseUrl: string,
  user: string,
  password: string,
  payload: JsonObj,
  req: { timeoutMs: number; insecureTls: boolean }
): Promise<void> {
  await pmmRequest({
    baseUrl,
    user,
    password,
    method: "POST",
    path: "/v1/alerting/rules",
    body: payload,
    timeoutMs: req.timeoutMs,
    insecureTls: req.insecureTls,
  });
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function sha256Hex(text: string): string {
  return crypto.createHash("sha256").update(text, "utf8").digest("hex");
}

export async function runController(): Promise<void> {
  const configMapName = envOptional("ALERT_RULES_CONFIGMAP", "pxc-pmm-alert-rules");
  const configMapKey = envOptional("ALERT_RULES_KEY", "rules.json");
  const namespace = process.env.ALERT_RULES_NAMESPACE?.trim() || readNamespaceFromServiceAccount();
  const pmmBaseUrl = envOptional(
    "PMM_URL",
    "https://monitoring-service.pmm.svc.cluster.local"
  ).replace(/\/+$/, "");
  const ruleGroupName = envOptional("RULE_GROUP_NAME", "pxc-pmm");
  /** All expr-based rules are stored in this single Grafana rule group (one ruler POST) so all survive under the MySQL folder. */
  const exprRuleBatchGroupName = envOptional("EXPR_RULE_BATCH_GROUP", "pxc-pmm-expr");
  const syncIntervalMs = parseIntEnv("SYNC_INTERVAL_MS", 60_000);
  if (!Number.isFinite(syncIntervalMs) || syncIntervalMs < 5000) throw new Error("SYNC_INTERVAL_MS must be >= 5000");
  const requestTimeoutMs = parseIntEnv("PMM_REQUEST_TIMEOUT_MS", 15_000);
  const insecureTls = parseBoolEnv("PMM_INSECURE_TLS", true);
  const reqOpts = { timeoutMs: requestTimeoutMs, insecureTls };

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

    logLine(
      `pxc-pmm-alerts-controller started pmmUrl=${pmmBaseUrl} ns=${namespace} cm=${configMapName}/${configMapKey} ` +
        `ruleGroup=${ruleGroupName} exprBatchGroup=${exprRuleBatchGroupName} syncIntervalMs=${syncIntervalMs} requestTimeoutMs=${requestTimeoutMs} insecureTls=${insecureTls}`
    );

    let lastRulesSha256 = "";

    while (!stopping) {
      const cycleStart = Date.now();
      try {
        const cfg = await core.readNamespacedConfigMap({ name: configMapName, namespace });
        const rawRulesPeek = cfg.data?.[configMapKey];
        if (!rawRulesPeek) throw new Error(`ConfigMap ${namespace}/${configMapName} missing key ${configMapKey}`);
        const rulesDigest = sha256Hex(rawRulesPeek);
        const forceEveryCycle = parseBoolEnv("FORCE_SYNC_EVERY_CYCLE", false);
        if (!forceEveryCycle && rulesDigest === lastRulesSha256) {
          logLine(`sync skipped: rules.json unchanged digest=${rulesDigest.slice(0, 12)}…`);
          await sleep(syncIntervalMs);
          continue;
        }

        logLine("sync: resolving MySQL folder UID…");
        const folderUid = await resolveMySqlFolderUid(pmmBaseUrl, user, password, reqOpts);
        logLine(`sync: MySQL folder uid=${folderUid}`);
        logLine("sync: resolving Grafana datasource UID…");
        const datasourceUid = await resolveDatasourceUid(pmmBaseUrl, user, password, reqOpts);
        logLine(`sync: datasource uid=${datasourceUid}`);
        const rawRules = rawRulesPeek;

        const desiredRules = parseRules(rawRules).map((rule) =>
          deepReplace(rule, {
            "__MYSQL_FOLDER_UID__": folderUid,
            "${MYSQL_FOLDER_UID}": folderUid,
          })
        ) as JsonObj[];

        const templateRules = desiredRules.filter((r) => ruleUsesPmmTemplate(r));
        const exprRules = desiredRules.filter((r) => !ruleUsesPmmTemplate(r));

        logLine(
          `sync: clearing Grafana groups folderUid=${folderUid} templateGroup=${ruleGroupName} batchGroup=${exprRuleBatchGroupName}…`
        );
        await deleteRulerRuleGroup({
          baseUrl: pmmBaseUrl,
          user,
          password,
          folderUid,
          ruleGroupName,
          timeoutMs: requestTimeoutMs,
          insecureTls,
        });
        await deleteRulerRuleGroup({
          baseUrl: pmmBaseUrl,
          user,
          password,
          folderUid,
          ruleGroupName: exprRuleBatchGroupName,
          timeoutMs: requestTimeoutMs,
          insecureTls,
        });
        for (const r of exprRules) {
          await deleteRulerRuleGroup({
            baseUrl: pmmBaseUrl,
            user,
            password,
            folderUid,
            ruleGroupName: getRuleName(r),
            timeoutMs: requestTimeoutMs,
            insecureTls,
          });
        }

        let applied = 0;
        for (const desired of templateRules) {
          const name = getRuleName(desired);
          await createRule(pmmBaseUrl, user, password, desired, reqOpts);
          logLine(`posted PMM template rule: ${name}`);
          applied += 1;
        }

        if (exprRules.length > 0) {
          const batch = buildBatchedExprRulerGroup(exprRules, datasourceUid, exprRuleBatchGroupName);
          logLine(
            `sync: posting ${exprRules.length} expr rules in one Grafana group "${exprRuleBatchGroupName}"…`
          );
          await postBatchedExprRulerGroup({
            baseUrl: pmmBaseUrl,
            user,
            password,
            folderUid,
            body: batch,
            timeoutMs: requestTimeoutMs,
            insecureTls,
          });
          applied += exprRules.length;
        }

        lastRulesSha256 = rulesDigest;
        logLine(`sync: applied ${applied} rules in ${Date.now() - cycleStart}ms digest=${rulesDigest.slice(0, 12)}…`);
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
