import * as crypto from "crypto";
import { logLine } from "./log";

export type JsonValue = null | boolean | number | string | JsonValue[] | { [key: string]: JsonValue };
export type JsonObj = { [key: string]: JsonValue };

/** Label written on template rules so we can tell PMM/Grafana state matches desired ConfigMap fields without a PMM GET rules API. */
export const MANAGED_DIGEST_LABEL = "pxc_pmm_managed_digest";

export interface PmmClient {
  fetchRulerRuleGroups(folderUid: string): Promise<JsonObj[] | null>;
  /** Same path as {@link fetchRulerRuleGroups} but throws on HTTP failure (used after ruler DELETE to poll until the group is gone). */
  fetchRulerRuleGroupsStrict(folderUid: string): Promise<JsonObj[]>;
  /** Grafana unified alerting rules (may be null if API unavailable). */
  listProvisioningAlertRules(): Promise<JsonObj[] | null>;
  deleteProvisioningAlertRuleByUid(uid: string): Promise<void>;
  postBatchedExprRulerGroup(folderUid: string, body: JsonObj): Promise<void>;
  deleteRulerRuleGroup(folderUid: string, ruleGroupName: string): Promise<void>;
  createAlertingRule(payload: JsonObj): Promise<void>;
}

export function parseRules(jsonPayload: string): JsonObj[] {
  const parsed = JSON.parse(jsonPayload) as JsonValue;
  if (!Array.isArray(parsed) || parsed.length === 0) {
    throw new Error("ConfigMap value must be a non-empty JSON array");
  }
  const rules = parsed.filter((x): x is JsonObj => !!x && typeof x === "object" && !Array.isArray(x));
  if (rules.length !== parsed.length) throw new Error("Every alert payload must be a JSON object");
  return rules;
}

export function deepReplace(value: JsonValue, replacements: Record<string, string>): JsonValue {
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

export function getRuleName(rule: JsonObj): string {
  const candidates = [rule.name, rule.alert_name, rule.title];
  for (const c of candidates) {
    if (typeof c === "string" && c.trim()) return c.trim();
  }
  throw new Error(`Rule missing name/title field: ${JSON.stringify(rule)}`);
}

export function ruleUsesPmmTemplate(rule: JsonObj): boolean {
  const t = rule.template_name;
  return typeof t === "string" && t.trim().length > 0;
}

/** One `rules[]` entry for the Grafana ruler API (see `projects/pmm/default.nix`). */
export function buildGrafanaExprRuleEntry(rule: JsonObj, datasourceUid: string): JsonObj {
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
export function buildBatchedExprRulerGroup(exprRules: JsonObj[], datasourceUid: string, batchGroupName: string): JsonObj {
  if (exprRules.length === 0) throw new Error("buildBatchedExprRulerGroup: no expr rules");
  return {
    name: batchGroupName,
    interval: "1m",
    rules: exprRules.map((r) => buildGrafanaExprRuleEntry(r, datasourceUid)),
  };
}

export function sha256Hex(text: string): string {
  return crypto.createHash("sha256").update(text, "utf8").digest("hex");
}

export function sortKeysDeep(value: JsonValue): JsonValue {
  if (Array.isArray(value)) return value.map(sortKeysDeep);
  if (value && typeof value === "object") {
    const obj = value as JsonObj;
    const sorted: JsonObj = {};
    for (const key of Object.keys(obj).sort()) {
      sorted[key] = sortKeysDeep(obj[key]);
    }
    return sorted;
  }
  return value;
}

export function stableStringify(value: JsonValue): string {
  return JSON.stringify(sortKeysDeep(value));
}

/** Best-effort parse of Go-style durations (5m, 120s, 1h30m) to seconds for compare. */
export function parseDurationToSecondsApprox(d: string): number {
  const s = d.trim();
  if (!s) return 0;
  let total = 0;
  const re = /(\d+(?:\.\d+)?)(ns|us|µs|ms|s|m|h)/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(s)) !== null) {
    const v = parseFloat(m[1]);
    const u = m[2];
    const mul =
      u === "h" ? 3600 : u === "m" ? 60 : u === "s" ? 1 : u === "ms" ? 0.001 : u === "us" || u === "µs" ? 1e-6 : u === "ns" ? 1e-9 : 1;
    total += v * mul;
  }
  return Math.round(total * 1000) / 1000;
}

export function normalizeExprForCompare(expr: string): string {
  return expr.trim().replace(/\s+/g, " ");
}

export function isPostableRuleGroupNode(x: JsonValue): x is JsonObj {
  if (!x || typeof x !== "object" || Array.isArray(x)) return false;
  const o = x as JsonObj;
  return typeof o.name === "string" && Array.isArray(o.rules);
}

/**
 * Grafana ruler GET body shape varies (arrays of groups, nested maps, folder/subfolder keys).
 * Recursively collect objects that look like PostableRuleGroup { name, rules[] }.
 */
export function flattenRulerGroupsFromResponse(resp: JsonValue): JsonObj[] {
  const byName = new Map<string, JsonObj>();
  const walk = (node: JsonValue): void => {
    if (node === null || node === undefined) return;
    if (Array.isArray(node)) {
      for (const el of node) walk(el);
      return;
    }
    if (typeof node !== "object") return;
    const o = node as JsonObj;
    if (isPostableRuleGroupNode(o)) {
      const name = o.name as string;
      const prev = byName.get(name);
      if (!prev) {
        byName.set(name, o);
      } else {
        const a = Array.isArray(prev.rules) ? (prev.rules as JsonObj[]) : [];
        const b = Array.isArray(o.rules) ? (o.rules as JsonObj[]) : [];
        byName.set(name, { ...prev, rules: [...a, ...b] });
      }
      return;
    }
    for (const v of Object.values(o)) walk(v as JsonValue);
  };
  walk(resp);
  return Array.from(byName.values());
}

export function findRuleGroup(groups: JsonObj[], name: string): JsonObj | undefined {
  return groups.find((g) => typeof g.name === "string" && g.name === name);
}

/** Grafana injects labels; ignore those so ConfigMap labels still match. Coerce values to strings for stable compare. */
export function exprLabelsForCompare(labels: JsonValue): JsonObj {
  if (!labels || typeof labels !== "object" || Array.isArray(labels)) return {};
  const out: JsonObj = {};
  for (const [k, v] of Object.entries(labels as JsonObj)) {
    if (k.startsWith("__")) continue;
    if (k === "grafana_folder" || k === "alertname" || k === "grafana_instance") continue;
    if (v === null || v === undefined) continue;
    out[k] = typeof v === "string" ? v : typeof v === "boolean" || typeof v === "number" ? String(v) : JSON.stringify(v);
  }
  return sortKeysDeep(out) as JsonObj;
}

/** Matches {@link buildBatchedExprRulerGroup} default `interval: "1m"` when Grafana omits or coerces the field. */
export function normalizedBatchIntervalForCompare(batch: JsonObj): string {
  const iv = batch.interval;
  if (typeof iv === "number" && Number.isFinite(iv)) {
    return `${iv}s`;
  }
  if (typeof iv === "string" && iv.trim()) {
    return iv.trim();
  }
  return "1m";
}

/** Stable `for` duration string for compare; Grafana GET may omit `for` or use numeric seconds. */
export function normalizedRuleForForCompare(rule: JsonObj, ga: JsonObj): string {
  const fromRule = rule.for;
  if (typeof fromRule === "string" && fromRule.trim()) {
    return fromRule.trim();
  }
  if (typeof fromRule === "number" && Number.isFinite(fromRule)) {
    return `${fromRule}s`;
  }
  const fromGa = ga.for;
  if (typeof fromGa === "string" && fromGa.trim()) {
    return fromGa.trim();
  }
  if (typeof fromGa === "number" && Number.isFinite(fromGa)) {
    return `${fromGa}s`;
  }
  return "60s";
}

/** One comparable row per alert (Grafana stores extra fields in data/model that break JSON equality). */
export function extractExprRuleCompareRows(batch: JsonObj): JsonObj[] {
  const rules = batch.rules;
  if (!Array.isArray(rules)) return [];
  const rows: JsonObj[] = [];
  for (const r of rules) {
    if (!r || typeof r !== "object" || Array.isArray(r)) continue;
    const rule = r as JsonObj;
    const ga = rule.grafana_alert;
    if (!ga || typeof ga !== "object" || Array.isArray(ga) || !Array.isArray((ga as JsonObj).data)) continue;
    let expr = "";
    for (const q of (ga as JsonObj).data as JsonValue[]) {
      if (!q || typeof q !== "object" || Array.isArray(q)) continue;
      const model = (q as JsonObj).model;
      if (model && typeof model === "object" && !Array.isArray(model) && typeof (model as JsonObj).expr === "string") {
        expr = normalizeExprForCompare(String((model as JsonObj).expr));
        break;
      }
    }
    const title = typeof (ga as JsonObj).title === "string" ? ((ga as JsonObj).title as string).trim() : "";
    const noData =
      typeof (ga as JsonObj).no_data_state === "string" ? ((ga as JsonObj).no_data_state as string) : "OK";
    const execErr =
      typeof (ga as JsonObj).exec_err_state === "string"
        ? ((ga as JsonObj).exec_err_state as string)
        : "Alerting";
    const forRaw = normalizedRuleForForCompare(rule, ga as JsonObj);
    rows.push(
      sortKeysDeep({
        title,
        for_sec: parseDurationToSecondsApprox(forRaw),
        expr,
        no_data_state: noData,
        exec_err_state: execErr,
        labels: exprLabelsForCompare(rule.labels ?? {}),
      }) as JsonObj
    );
  }
  rows.sort((a, b) => String(a.title).localeCompare(String(b.title)));
  return rows;
}

export function exprBatchSemanticKey(batch: JsonObj): string {
  const name = typeof batch.name === "string" ? batch.name : "";
  const intervalRaw = normalizedBatchIntervalForCompare(batch);
  const rules = extractExprRuleCompareRows(batch);
  return stableStringify(
    sortKeysDeep({
      name,
      interval_sec: parseDurationToSecondsApprox(intervalRaw),
      rules,
    }) as JsonValue
  );
}

export function exprBatchesSemanticallyEqual(want: JsonObj, got: JsonObj): boolean {
  return exprBatchSemanticKey(want) === exprBatchSemanticKey(got);
}

function looksLikeManagedExprGroup(group: JsonObj): boolean {
  const rows = extractExprRuleCompareRows(group);
  return rows.length > 0;
}

export function isDuplicatePmmTemplateRuleError(err: unknown): boolean {
  const msg = err instanceof Error ? err.message : String(err);
  if (!msg.includes("POST /v1/alerting/rules")) return false;
  if (!msg.includes("400")) return false;
  return msg.includes("unique") || msg.includes("conflicts with existing");
}

export function isDuplicateExprRulerConflictError(err: unknown): boolean {
  const msg = err instanceof Error ? err.message : String(err);
  if (!msg.includes("POST /graph/api/ruler/")) return false;
  if (!msg.includes("409")) return false;
  return msg.includes("unique") || msg.includes("conflicts with existing");
}

/** Comparable subset of a ConfigMap template rule (what we control). */
export function templateDesiredComparable(rule: JsonObj): JsonObj {
  return sortKeysDeep({
    template_name: rule.template_name,
    name: getRuleName(rule),
    group: rule.group,
    folder_uid: rule.folder_uid,
    params: rule.params ?? [],
    for: typeof rule.for === "string" ? rule.for : "60s",
    severity: rule.severity,
    custom_labels: rule.custom_labels ?? {},
    filters: rule.filters ?? [],
  }) as JsonObj;
}

export function templateDesiredDigest(rule: JsonObj): string {
  return sha256Hex(stableStringify(templateDesiredComparable(rule)));
}

/** Merge managed digest into POST body so the next GET can confirm this rule matches ConfigMap. */
export function withManagedTemplateDigest(rule: JsonObj): JsonObj {
  const digest = templateDesiredDigest(rule);
  const raw = rule.custom_labels;
  const base =
    raw && typeof raw === "object" && !Array.isArray(raw) ? ({ ...raw } as JsonObj) : {};
  base[MANAGED_DIGEST_LABEL] = digest;
  return { ...rule, custom_labels: base };
}

export function indexTemplateRulesByTitle(templateGroup: JsonObj | undefined): Map<string, JsonObj> {
  const map = new Map<string, JsonObj>();
  if (!templateGroup?.rules || !Array.isArray(templateGroup.rules)) return map;
  for (const r of templateGroup.rules) {
    if (!r || typeof r !== "object" || Array.isArray(r)) continue;
    const rule = r as JsonObj;
    const ga = rule.grafana_alert;
    const title =
      ga && typeof ga === "object" && !Array.isArray(ga) && typeof (ga as JsonObj).title === "string"
        ? ((ga as JsonObj).title as string).trim()
        : "";
    if (title) map.set(title, rule);
  }
  return map;
}

function delay(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function provisionedRuleFolderUid(rule: JsonObj): string {
  const v = rule.folder_uid ?? rule.folderUID ?? rule.folderUid;
  return typeof v === "string" ? v : "";
}

function provisionedRuleTitle(rule: JsonObj): string {
  const v = rule.title ?? rule.rule_title;
  return typeof v === "string" ? v.trim() : "";
}

function provisionedRuleUid(rule: JsonObj): string {
  const v = rule.uid ?? rule.rule_uid ?? rule.Uid;
  return typeof v === "string" ? v.trim() : "";
}

/** Normalize Grafana provisioning list responses (array or `{ rules: [...] }`). */
export function provisioningAlertRulesFromResponse(raw: JsonValue): JsonObj[] | null {
  if (Array.isArray(raw)) return raw.filter((x) => x && typeof x === "object" && !Array.isArray(x)) as JsonObj[];
  if (raw && typeof raw === "object" && !Array.isArray(raw)) {
    const r = raw as JsonObj;
    const rules = r.rules;
    if (Array.isArray(rules))
      return rules.filter((x) => x && typeof x === "object" && !Array.isArray(x)) as JsonObj[];
  }
  return null;
}

/**
 * PMM POST /v1/alerting/rules can fail with "conflicts with existing … title: ''" after ruler DELETE — the stale row is often only visible via Grafana provisioning.
 */
export async function deleteConflictingProvisionedAlertRules(args: {
  pmm: PmmClient;
  folderUid: string;
  templateRuleTitles: Set<string>;
  log?: (msg: string) => void;
}): Promise<number> {
  const log = args.log ?? (() => {});
  const rows = await args.pmm.listProvisioningAlertRules();
  if (!rows?.length) return 0;
  let deleted = 0;
  for (const rule of rows) {
    if (provisionedRuleFolderUid(rule) !== args.folderUid) continue;
    const uid = provisionedRuleUid(rule);
    if (!uid) continue;
    const title = provisionedRuleTitle(rule);
    const isManagedTitle = args.templateRuleTitles.has(title);
    const orphanTitle = title.length === 0;
    if (!isManagedTitle && !orphanTitle) continue;
    await args.pmm.deleteProvisioningAlertRuleByUid(uid);
    log(
      `sync: deleted Grafana provisioned alert rule uid=${uid} title=${JSON.stringify(title || "(empty)")} before template repost`
    );
    deleted += 1;
  }
  return deleted;
}

/** After deleting a Grafana ruler group, PMM may still reject POST /v1/alerting/rules until the ruler view catches up. Poll until the group name is absent. */
export async function waitUntilRulerGroupAbsent(args: {
  fetchStrict: () => Promise<JsonObj[]>;
  ruleGroupName: string;
  maxWaitMs: number;
  pollIntervalMs: number;
}): Promise<void> {
  const deadline = Date.now() + args.maxWaitMs;
  while (Date.now() < deadline) {
    const groups = await args.fetchStrict();
    if (!findRuleGroup(groups, args.ruleGroupName)) return;
    await delay(args.pollIntervalMs);
  }
  throw new Error(
    `Grafana ruler rule group "${args.ruleGroupName}" still present after delete; exceeded ${args.maxWaitMs}ms`
  );
}

export function templateRuleInSync(desired: JsonObj, actual: JsonObj | undefined): boolean {
  if (!actual) return false;
  const wantDigest = templateDesiredDigest(desired);
  const labels =
    actual.labels && typeof actual.labels === "object" && !Array.isArray(actual.labels)
      ? (actual.labels as JsonObj)
      : {};
  const gotDigest = typeof labels[MANAGED_DIGEST_LABEL] === "string" ? labels[MANAGED_DIGEST_LABEL] : "";
  if (gotDigest !== wantDigest) return false;
  const ga = actual.grafana_alert;
  const title =
    ga && typeof ga === "object" && !Array.isArray(ga) ? (ga as JsonObj).title : undefined;
  return typeof title === "string" && title.trim() === getRuleName(desired);
}

export async function syncIncremental(args: {
  pmm: PmmClient;
  folderUid: string;
  datasourceUid: string;
  ruleGroupName: string;
  exprRuleBatchGroupName: string;
  templateRules: JsonObj[];
  exprRules: JsonObj[];
}): Promise<number> {
  const { pmm, folderUid, datasourceUid, ruleGroupName, exprRuleBatchGroupName, templateRules, exprRules } = args;

  const groups = await pmm.fetchRulerRuleGroups(folderUid);
  if (!groups) {
    return 0;
  }

  const templateGroup = findRuleGroup(groups, ruleGroupName);
  const byTitle = indexTemplateRulesByTitle(templateGroup);

  let applied = 0;
  let repostedTemplatesAfterDuplicate = false;
  outerTemplates: for (const desired of templateRules) {
    const name = getRuleName(desired);
    if (templateRuleInSync(desired, byTitle.get(name))) continue;
    try {
      await pmm.createAlertingRule(withManagedTemplateDigest(desired));
      logLine(`sync: updated PMM template rule (incremental): ${name}`);
      applied += 1;
    } catch (e: unknown) {
      if (!isDuplicatePmmTemplateRuleError(e) || repostedTemplatesAfterDuplicate) throw e;
      logLine(
        `sync: PMM duplicate template rule "${name}"; deleting Grafana group "${ruleGroupName}" and reposting all template rules…`
      );
      await pmm.deleteRulerRuleGroup(folderUid, ruleGroupName);
      await waitUntilRulerGroupAbsent({
        fetchStrict: () => pmm.fetchRulerRuleGroupsStrict(folderUid),
        ruleGroupName,
        maxWaitMs: 30000,
        pollIntervalMs: 500,
      });
      const titles = new Set(templateRules.map((r) => getRuleName(r)));
      await deleteConflictingProvisionedAlertRules({
        pmm,
        folderUid,
        templateRuleTitles: titles,
        log: logLine,
      });
      for (const d of templateRules) {
        await pmm.createAlertingRule(withManagedTemplateDigest(d));
        logLine(`sync: reposted PMM template rule: ${getRuleName(d)}`);
        applied += 1;
      }
      repostedTemplatesAfterDuplicate = true;
      break outerTemplates;
    }
  }

  const desiredExprNames = new Set(exprRules.map((r) => getRuleName(r)));
  for (const desired of exprRules) {
    const groupName = getRuleName(desired);
    const want = buildBatchedExprRulerGroup([desired], datasourceUid, groupName);
    const got = findRuleGroup(groups, groupName);
    if (got && exprBatchesSemanticallyEqual(want, got)) continue;

    if (got) {
      await pmm.deleteRulerRuleGroup(folderUid, groupName);
      await waitUntilRulerGroupAbsent({
        fetchStrict: () => pmm.fetchRulerRuleGroupsStrict(folderUid),
        ruleGroupName: groupName,
        maxWaitMs: 30000,
        pollIntervalMs: 500,
      });
    }
    logLine(`sync: posting expr rule "${groupName}" in Grafana group "${groupName}"…`);
    try {
      await pmm.postBatchedExprRulerGroup(folderUid, want);
    } catch (e: unknown) {
      if (!isDuplicateExprRulerConflictError(e)) throw e;
      logLine(
        `sync: Grafana expr conflict on group "${groupName}"; deleting stale group/provisioned rows and retrying once…`
      );
      await pmm.deleteRulerRuleGroup(folderUid, groupName);
      await waitUntilRulerGroupAbsent({
        fetchStrict: () => pmm.fetchRulerRuleGroupsStrict(folderUid),
        ruleGroupName: groupName,
        maxWaitMs: 30000,
        pollIntervalMs: 500,
      });
      await deleteConflictingProvisionedAlertRules({
        pmm,
        folderUid,
        templateRuleTitles: new Set([groupName]),
        log: logLine,
      });
      await pmm.postBatchedExprRulerGroup(folderUid, want);
    }
    applied += 1;
  }

  // Remove old batch group and orphaned per-rule expr groups no longer declared in ConfigMap.
  // Never touch `ruleGroupName` here: PMM template rules live in that Grafana group and can look
  // expr-shaped to `looksLikeManagedExprGroup` (queries in `grafana_alert.data`).
  for (const g of groups) {
    const name = typeof g.name === "string" ? g.name : "";
    if (!name) continue;
    if (name === ruleGroupName) continue;
    if (name === exprRuleBatchGroupName || (looksLikeManagedExprGroup(g) && !desiredExprNames.has(name))) {
      await pmm.deleteRulerRuleGroup(folderUid, name);
      logLine(`sync: removed stale expr rule group "${name}"`);
    }
  }

  return applied;
}
