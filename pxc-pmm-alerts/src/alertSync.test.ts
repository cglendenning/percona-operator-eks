import { beforeEach, describe, expect, it, vi } from "vitest";

vi.mock("./log", () => ({ logLine: vi.fn() }));

import { logLine } from "./log";
import {
  MANAGED_DIGEST_LABEL,
  buildBatchedExprRulerGroup,
  buildGrafanaExprRuleEntry,
  deepReplace,
  exprBatchesSemanticallyEqual,
  deleteConflictingProvisionedAlertRules,
  flattenRulerGroupsFromResponse,
  getRuleName,
  isDuplicatePmmTemplateRuleError,
  isDuplicateExprRulerConflictError,
  normalizeExprForCompare,
  parseDurationToSecondsApprox,
  parseRules,
  provisioningAlertRulesFromResponse,
  ruleUsesPmmTemplate,
  sha256Hex,
  sortKeysDeep,
  stableStringify,
  syncIncremental,
  templateDesiredDigest,
  templateRuleInSync,
  waitUntilRulerGroupAbsent,
  withManagedTemplateDigest,
  type JsonObj,
  type JsonValue,
  type PmmClient,
} from "./alertSync";

describe("parseRules", () => {
  it("parses a non-empty object array", () => {
    const r = parseRules(`[{"name":"a","expr":"up"}]`);
    expect(r).toHaveLength(1);
    expect(r[0].name).toBe("a");
  });

  it("throws on empty array", () => {
    expect(() => parseRules("[]")).toThrow(/non-empty/);
  });

  it("throws when an element is not an object", () => {
    expect(() => parseRules(`["x"]`)).toThrow(/JSON object/);
  });
});

describe("deepReplace", () => {
  it("replaces nested placeholders", () => {
    const out = deepReplace({ q: ["__MYSQL_FOLDER_UID__/x"] } as JsonObj, {
      __MYSQL_FOLDER_UID__: "uid-9",
    }) as JsonObj;
    expect(out.q).toEqual(["uid-9/x"]);
  });
});

describe("getRuleName / ruleUsesPmmTemplate", () => {
  it("prefers name over title", () => {
    expect(getRuleName({ name: "n", title: "t" } as JsonObj)).toBe("n");
  });

  it("detects template rules", () => {
    expect(ruleUsesPmmTemplate({ template_name: "  x  " } as JsonObj)).toBe(true);
    expect(ruleUsesPmmTemplate({ name: "a" } as JsonObj)).toBe(false);
  });
});

describe("buildGrafanaExprRuleEntry / buildBatchedExprRulerGroup", () => {
  it("embeds datasourceUid in the prometheus query ref", () => {
    const row = buildGrafanaExprRuleEntry({ name: "E", expr: `up `, for: "2m" } as JsonObj, "ds-1");
    const ga = row.grafana_alert as JsonObj;
    const data = ga.data as JsonObj[];
    expect((data[0] as JsonObj).datasourceUid).toBe("ds-1");
    expect((((data[0] as JsonObj).model as JsonObj).expr as string).trim()).toBe("up");
    expect(row.for).toBe("2m");
  });

  it("throws when expr is missing", () => {
    expect(() => buildGrafanaExprRuleEntry({ name: "X" } as JsonObj, "ds")).toThrow(/missing expr/);
  });

  it("builds a batch group with interval 1m", () => {
    const batch = buildBatchedExprRulerGroup([{ name: "A", expr: "1" } as JsonObj], "ds", "batch-g");
    expect(batch.name).toBe("batch-g");
    expect(batch.interval).toBe("1m");
    expect((batch.rules as JsonObj[]).length).toBe(1);
  });
});

describe("stableStringify / sortKeysDeep", () => {
  it("is stable under key reorder", () => {
    const a = stableStringify({ z: 1, a: { y: 2, b: 3 } } as JsonObj);
    const b = stableStringify({ a: { b: 3, y: 2 }, z: 1 } as JsonObj);
    expect(a).toBe(b);
  });
});

describe("sha256Hex", () => {
  it("is deterministic", () => {
    expect(sha256Hex("hello")).toBe(sha256Hex("hello"));
    expect(sha256Hex("hello").length).toBe(64);
  });
});

describe("parseDurationToSecondsApprox / normalizeExprForCompare", () => {
  it("parses compound durations", () => {
    expect(parseDurationToSecondsApprox("5m")).toBe(300);
    expect(parseDurationToSecondsApprox("1m30s")).toBe(90);
  });

  it("normalizes expr whitespace", () => {
    expect(normalizeExprForCompare("  foo   bar  ")).toBe("foo bar");
  });
});

describe("flattenRulerGroupsFromResponse", () => {
  it("merges rules when the same group name appears multiple times (keeps first group metadata)", () => {
    const g1 = { name: "g", interval: "1m", rules: [{ a: 1 }] };
    const g2 = { name: "g", interval: "2m", rules: [{ b: 2 }] };
    const flat = flattenRulerGroupsFromResponse({
      outer: [{ nested: [g1] }, g2],
    } as JsonObj);
    expect(flat).toHaveLength(1);
    expect(flat[0].interval).toBe("1m");
    expect(flat[0].rules as JsonObj[]).toHaveLength(2);
  });
});

describe("exprBatchesSemanticallyEqual", () => {
  const ds = "prom-uid";
  const exprRules = [{ name: "AlertOne", expr: `sum(up)`, custom_labels: { team: "a" } }] as JsonObj[];

  it("treats semantically identical batches as equal", () => {
    const want = buildBatchedExprRulerGroup(exprRules, ds, "from-expression");
    const got = JSON.parse(JSON.stringify(want)) as JsonObj;
    expect(exprBatchesSemanticallyEqual(want, got)).toBe(true);
  });

  it("ignores Grafana-only label keys on the server copy", () => {
    const want = buildBatchedExprRulerGroup(exprRules, ds, "from-expression");
    const got = JSON.parse(JSON.stringify(want)) as JsonObj;
    const rules = got.rules as JsonObj[];
    const labels = { ...(rules[0].labels as JsonObj), __rule_uid__: "x", grafana_folder: "MySQL" };
    rules[0].labels = labels;
    expect(exprBatchesSemanticallyEqual(want, got)).toBe(true);
  });

  it("detects expr changes", () => {
    const want = buildBatchedExprRulerGroup(exprRules, ds, "from-expression");
    const got = JSON.parse(JSON.stringify(want)) as JsonObj;
    const ga = ((got.rules as JsonObj[])[0].grafana_alert as JsonObj).data as JsonObj[];
    (((ga[0].model as JsonObj).expr as string) = "down");
    expect(exprBatchesSemanticallyEqual(want, got)).toBe(false);
  });

  it("treats whitespace-only expr differences as equal", () => {
    const simple = [{ name: "AlertOne", expr: "up", custom_labels: { team: "a" } }] as JsonObj[];
    const want = buildBatchedExprRulerGroup(simple, ds, "from-expression");
    const got = JSON.parse(JSON.stringify(want)) as JsonObj;
    const ga = ((got.rules as JsonObj[])[0].grafana_alert as JsonObj).data as JsonObj[];
    (((ga[0].model as JsonObj).expr as string) = "  up  ");
    expect(exprBatchesSemanticallyEqual(want, got)).toBe(true);
  });

  it("treats Grafana batch omitting interval as same as default 1m", () => {
    const want = buildBatchedExprRulerGroup(exprRules, ds, "from-expression");
    const got = JSON.parse(JSON.stringify(want)) as JsonObj;
    delete got.interval;
    expect(exprBatchesSemanticallyEqual(want, got)).toBe(true);
  });

  it("treats numeric group interval as duration seconds", () => {
    const want = buildBatchedExprRulerGroup(exprRules, ds, "from-expression");
    const got = JSON.parse(JSON.stringify(want)) as JsonObj;
    got.interval = 60 as unknown as JsonValue;
    expect(exprBatchesSemanticallyEqual(want, got)).toBe(true);
  });

  it("treats numeric rule.for as seconds matching string duration", () => {
    const want = buildBatchedExprRulerGroup(exprRules, ds, "from-expression");
    const got = JSON.parse(JSON.stringify(want)) as JsonObj;
    const row = (got.rules as JsonObj[])[0];
    delete row.for;
    row.for = 300 as unknown as JsonValue;
    ((row.grafana_alert as JsonObj).for as JsonValue) = 300 as unknown as JsonValue;
    const wantFive = buildBatchedExprRulerGroup(
      [{ ...exprRules[0], for: "5m" }] as JsonObj[],
      ds,
      "from-expression"
    );
    expect(exprBatchesSemanticallyEqual(wantFive, got)).toBe(true);
  });
});

describe("isDuplicatePmmTemplateRuleError", () => {
  it("matches PMM duplicate template errors", () => {
    expect(
      isDuplicatePmmTemplateRuleError(
        new Error(`PMM API POST /v1/alerting/rules failed: 400 {"message":"unique"}`)
      )
    ).toBe(true);
    expect(isDuplicatePmmTemplateRuleError(new Error("random"))).toBe(false);
  });
});

describe("isDuplicateExprRulerConflictError", () => {
  it("matches Grafana ruler conflict errors", () => {
    expect(
      isDuplicateExprRulerConflictError(
        new Error(
          `PMM API POST /graph/api/ruler/grafana/api/v1/rules/fld failed: 409 {"message":"conflicts with existing"}`
        )
      )
    ).toBe(true);
    expect(isDuplicateExprRulerConflictError(new Error("random"))).toBe(false);
  });
});

describe("template digest / templateRuleInSync", () => {
  const template = {
    template_name: "pxc_high",
    name: "MyAlert",
    group: "from-template",
    params: [],
    for: "5m",
  } as JsonObj;

  it("writes digest label and matches round-trip", () => {
    const withDig = withManagedTemplateDigest(template);
    const labels = withDig.custom_labels as JsonObj;
    expect(typeof labels[MANAGED_DIGEST_LABEL]).toBe("string");
    expect(templateDesiredDigest(template)).toBe(labels[MANAGED_DIGEST_LABEL]);
    const actual = {
      labels,
      grafana_alert: { title: "MyAlert" },
    } as JsonObj;
    expect(templateRuleInSync(template, actual)).toBe(true);
  });

  it("fails when digest mismatches", () => {
    const actual = {
      labels: { [MANAGED_DIGEST_LABEL]: "wrong" },
      grafana_alert: { title: "MyAlert" },
    } as JsonObj;
    expect(templateRuleInSync(template, actual)).toBe(false);
  });
});

describe("provisioningAlertRulesFromResponse / deleteConflictingProvisionedAlertRules", () => {
  it("parses array or wrapped rules", () => {
    expect(provisioningAlertRulesFromResponse([])).toEqual([]);
    expect(provisioningAlertRulesFromResponse([{ uid: "u1" } as JsonObj])).toHaveLength(1);
    expect(provisioningAlertRulesFromResponse({ rules: [{ uid: "u1" } as JsonObj] } as JsonObj)).toHaveLength(1);
    expect(provisioningAlertRulesFromResponse(null)).toBe(null);
  });

  it("deletes rules in folder when title matches a template name or title is empty", async () => {
    const deleted: string[] = [];
    const pmm: PmmClient = {
      fetchRulerRuleGroups: async () => [],
      fetchRulerRuleGroupsStrict: async () => [],
      listProvisioningAlertRules: async () =>
        [
          { uid: "a", folder_uid: "fld", title: "MySQL Instance Down" },
          { uid: "b", folder_uid: "fld", title: "" },
          { uid: "c", folder_uid: "other", title: "MySQL Instance Down" },
        ] as JsonObj[],
      deleteProvisioningAlertRuleByUid: async (uid: string) => {
        deleted.push(uid);
      },
      postBatchedExprRulerGroup: async () => {},
      deleteRulerRuleGroup: async () => {},
      createAlertingRule: async () => {},
    };
    const n = await deleteConflictingProvisionedAlertRules({
      pmm,
      folderUid: "fld",
      templateRuleTitles: new Set(["MySQL Instance Down"]),
    });
    expect(n).toBe(2);
    expect(deleted.sort()).toEqual(["a", "b"]);
  });
});

describe("waitUntilRulerGroupAbsent", () => {
  it("resolves after fetchStrict no longer returns the group", async () => {
    let calls = 0;
    await waitUntilRulerGroupAbsent({
      fetchStrict: async () => {
        calls += 1;
        return calls < 2 ? ([{ name: "from-template", rules: [] }] as JsonObj[]) : [];
      },
      ruleGroupName: "from-template",
      maxWaitMs: 5000,
      pollIntervalMs: 1,
    });
    expect(calls).toBe(2);
  });
});

describe("syncIncremental", () => {
  const folderUid = "fld-1";
  const datasourceUid = "ds-1";
  const ruleGroupName = "template";
  const exprRuleBatchGroupName = "expression";

  beforeEach(() => {
    vi.mocked(logLine).mockClear();
  });

  function mkPmm(overrides: Partial<PmmClient> & { rulerGroups?: JsonObj[] | null }): PmmClient & {
    trace: string[];
  } {
    const trace: string[] = [];
    const rulerGroupsMut = [...(overrides.rulerGroups ?? [])];
    return {
      trace,
      listProvisioningAlertRules: async () => {
        trace.push("provList");
        const v = await overrides.listProvisioningAlertRules?.();
        return v === undefined ? null : v;
      },
      deleteProvisioningAlertRuleByUid: async (uid: string) => {
        trace.push(`provDel:${uid}`);
        await overrides.deleteProvisioningAlertRuleByUid?.(uid);
      },
      fetchRulerRuleGroups: async (uid: string) => {
        trace.push(`fetch:${uid}`);
        const g = overrides.fetchRulerRuleGroups?.(uid);
        if (g !== undefined) return g;
        return rulerGroupsMut;
      },
      fetchRulerRuleGroupsStrict: async (uid: string) => {
        trace.push(`fetchStrict:${uid}`);
        const g = overrides.fetchRulerRuleGroups?.(uid);
        if (g !== undefined) {
          if (g === null) throw new Error("sync: GET failed");
          return g;
        }
        return rulerGroupsMut;
      },
      postBatchedExprRulerGroup: async (uid, body) => {
        trace.push(`postExpr:${uid}:${(body.name as string) ?? ""}`);
        await overrides.postBatchedExprRulerGroup?.(uid, body);
      },
      deleteRulerRuleGroup: async (uid, name) => {
        trace.push(`delete:${uid}:${name}`);
        const idx = rulerGroupsMut.findIndex((x) => typeof x.name === "string" && x.name === name);
        if (idx >= 0) rulerGroupsMut.splice(idx, 1);
        await overrides.deleteRulerRuleGroup?.(uid, name);
      },
      createAlertingRule: async (payload) => {
        trace.push(`create:${getRuleName(payload)}`);
        await overrides.createAlertingRule?.(payload);
      },
    };
  }

  it("returns 0 when ruler GET yields null", async () => {
    const pmm = mkPmm({ fetchRulerRuleGroups: async () => null });
    const n = await syncIncremental({
      pmm,
      folderUid,
      datasourceUid,
      ruleGroupName,
      exprRuleBatchGroupName,
      templateRules: [],
      exprRules: [{ name: "E", expr: "up" } as JsonObj],
    });
    expect(n).toBe(0);
    expect(pmm.trace.join("|")).toMatch(/^fetch:fld-1$/);
  });

  it("posts expr batch when absent on server", async () => {
    const exprRules = [{ name: "E", expr: "up" }] as JsonObj[];
    const pmm = mkPmm({ rulerGroups: [] });
    const n = await syncIncremental({
      pmm,
      folderUid,
      datasourceUid,
      ruleGroupName,
      exprRuleBatchGroupName,
      templateRules: [],
      exprRules,
    });
    expect(n).toBe(1);
    expect(pmm.trace.some((t) => t.startsWith("postExpr:"))).toBe(true);
  });

  it("does not post expr when batch already matches", async () => {
    const exprRules = [{ name: "E", expr: "up" }] as JsonObj[];
    const want = buildBatchedExprRulerGroup(exprRules, datasourceUid, "E");
    const pmm = mkPmm({ rulerGroups: [want] });
    const n = await syncIncremental({
      pmm,
      folderUid,
      datasourceUid,
      ruleGroupName,
      exprRuleBatchGroupName,
      templateRules: [],
      exprRules,
    });
    expect(n).toBe(0);
    expect(pmm.trace.every((t) => !t.startsWith("postExpr:"))).toBe(true);
  });

  it("deletes expr batch when ConfigMap has no expr rules but server still has batch", async () => {
    const stale = buildBatchedExprRulerGroup([{ name: "Old", expr: "up" } as JsonObj], datasourceUid, exprRuleBatchGroupName);
    const pmm = mkPmm({ rulerGroups: [stale] });
    const n = await syncIncremental({
      pmm,
      folderUid,
      datasourceUid,
      ruleGroupName,
      exprRuleBatchGroupName,
      templateRules: [],
      exprRules: [],
    });
    expect(n).toBe(0);
    expect(pmm.trace.some((t) => t.includes(`delete:${folderUid}:${exprRuleBatchGroupName}`))).toBe(true);
  });

  it("updates one template rule when out of sync", async () => {
    const tmpl = {
      template_name: "t",
      name: "AlertT",
      group: ruleGroupName,
      params: [],
    } as JsonObj;
    const pmm = mkPmm({
      rulerGroups: [{ name: ruleGroupName, rules: [] }],
    });
    const n = await syncIncremental({
      pmm,
      folderUid,
      datasourceUid,
      ruleGroupName,
      exprRuleBatchGroupName,
      templateRules: [tmpl],
      exprRules: [],
    });
    expect(n).toBe(1);
    expect(pmm.trace.some((t) => t === "create:AlertT")).toBe(true);
  });

  it("on duplicate template error deletes group and reposts all templates", async () => {
    const a = { template_name: "t", name: "Only", group: ruleGroupName, params: [] } as JsonObj;
    const b = { template_name: "t", name: "Other", group: ruleGroupName, params: [] } as JsonObj;
    let attempt = 0;
    const pmm = mkPmm({
      rulerGroups: [{ name: ruleGroupName, rules: [] }],
      createAlertingRule: async () => {
        attempt += 1;
        if (attempt === 1) {
          throw new Error(`PMM API POST /v1/alerting/rules failed: 400 unique`);
        }
      },
    });
    const n = await syncIncremental({
      pmm,
      folderUid,
      datasourceUid,
      ruleGroupName,
      exprRuleBatchGroupName,
      templateRules: [a, b],
      exprRules: [],
    });
    expect(n).toBe(2);
    expect(pmm.trace.some((t) => t === `delete:${folderUid}:${ruleGroupName}`)).toBe(true);
    expect(pmm.trace.filter((t) => t.startsWith("create:"))).toEqual([
      "create:Only",
      "create:Only",
      "create:Other",
    ]);
    expect(pmm.trace.some((t) => t.startsWith("fetchStrict:"))).toBe(true);
    expect(pmm.trace.some((t) => t === "provList")).toBe(true);
  });

  it("removes orphaned expr groups that are no longer declared", async () => {
    const legacyName = "LegacyAlert";
    const desiredName = "CurrentAlert";
    const legacyGroup = buildBatchedExprRulerGroup(
      [{ name: legacyName, expr: "up" } as JsonObj],
      datasourceUid,
      legacyName
    );
    const pmm = mkPmm({
      rulerGroups: [legacyGroup],
    });
    const n = await syncIncremental({
      pmm,
      folderUid,
      datasourceUid,
      ruleGroupName,
      exprRuleBatchGroupName,
      templateRules: [],
      exprRules: [{ name: desiredName, expr: "up" } as JsonObj],
    });
    expect(n).toBe(1);
    expect(pmm.trace.some((t) => t === `delete:${folderUid}:${legacyName}`)).toBe(true);
  });

  it("on expr 409 conflict deletes stale group/provisioned rows and reposts expr batch", async () => {
    const exprRules = [{ name: "No MySQL Instances Monitored", expr: "up == 0" } as JsonObj];
    let posts = 0;
    const pmm = mkPmm({
      rulerGroups: [],
      listProvisioningAlertRules: async () =>
        [{ uid: "ghost", folder_uid: folderUid, title: "" } as JsonObj],
      postBatchedExprRulerGroup: async () => {
        posts += 1;
        if (posts === 1) {
          throw new Error(
            `PMM API POST /graph/api/ruler/grafana/api/v1/rules/${folderUid} failed: 409 {"message":"conflicts with existing"}`
          );
        }
      },
    });

    const n = await syncIncremental({
      pmm,
      folderUid,
      datasourceUid,
      ruleGroupName,
      exprRuleBatchGroupName,
      templateRules: [],
      exprRules,
    });
    expect(n).toBe(1);
    expect(posts).toBe(2);
    expect(pmm.trace.some((t) => t === `delete:${folderUid}:No MySQL Instances Monitored`)).toBe(true);
    expect(pmm.trace.some((t) => t === "provList")).toBe(true);
    expect(pmm.trace.some((t) => t === "provDel:ghost")).toBe(true);
  });

  it("does not delete the template ruler group during expr orphan cleanup (name matches RULE_GROUP_NAME)", async () => {
    const fakeTemplateGroupLooksExpr = buildBatchedExprRulerGroup(
      [{ name: "InnerTitle", expr: "up" } as JsonObj],
      datasourceUid,
      ruleGroupName
    );
    const pmm = mkPmm({ rulerGroups: [fakeTemplateGroupLooksExpr] });
    await syncIncremental({
      pmm,
      folderUid,
      datasourceUid,
      ruleGroupName,
      exprRuleBatchGroupName,
      templateRules: [],
      exprRules: [{ name: "E", expr: "1" } as JsonObj],
    });
    expect(pmm.trace.every((t) => !t.startsWith(`delete:${folderUid}:${ruleGroupName}`))).toBe(true);
  });
});
