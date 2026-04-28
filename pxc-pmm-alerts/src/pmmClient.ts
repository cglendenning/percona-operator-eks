import * as http from "http";
import * as https from "https";
import {
  flattenRulerGroupsFromResponse,
  provisioningAlertRulesFromResponse,
  type JsonObj,
  type JsonValue,
} from "./alertSync";
import { logLine } from "./log";
import { URL } from "url";

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

export function createPmmClient(config: {
  baseUrl: string;
  user: string;
  password: string;
  timeoutMs: number;
  insecureTls: boolean;
}) {
  const { baseUrl, user, password, timeoutMs, insecureTls } = config;

  function request<T>(path: string, opts?: { method?: string; body?: unknown; okStatuses?: Set<number> }): Promise<T> {
    return pmmRequest<T>({
      baseUrl,
      user,
      password,
      path,
      method: opts?.method,
      body: opts?.body,
      timeoutMs,
      insecureTls,
      okStatuses: opts?.okStatuses,
    });
  }

  return {
    async resolveDatasourceUid(): Promise<string> {
      type Datasource = { uid?: string; type?: string; isDefault?: boolean };
      const datasources = await request<Datasource[]>("/graph/api/datasources");
      const preferred =
        datasources.find((ds) => (ds.type === "prometheus" || ds.type === "victoriametrics") && ds.uid) ||
        datasources.find((ds) => ds.isDefault && ds.uid) ||
        datasources.find((ds) => !!ds.uid);
      if (!preferred?.uid) throw new Error("Could not resolve Grafana datasource UID");
      return preferred.uid;
    },

    async resolveMySqlFolderUid(): Promise<string> {
      type Folder = { uid?: string; title?: string };
      const folders = await request<Folder[]>("/graph/api/folders");
      const mysqlFolder = folders.find((folder) => folder.title === "MySQL");
      if (!mysqlFolder?.uid) throw new Error("Could not find Grafana folder with title \"MySQL\"");
      return mysqlFolder.uid;
    },

    async fetchRulerRuleGroups(folderUid: string): Promise<JsonObj[] | null> {
      try {
        const raw = await request<JsonValue>(
          `/graph/api/ruler/grafana/api/v1/rules/${encodeURIComponent(folderUid)}`,
          { method: "GET" }
        );
        return flattenRulerGroupsFromResponse(raw);
      } catch (e: unknown) {
        const message = e instanceof Error ? e.message : String(e);
        logLine(`sync: GET Grafana ruler rules failed (${message}); skipping apply this cycle`);
        return null;
      }
    },

    async fetchRulerRuleGroupsStrict(folderUid: string): Promise<JsonObj[]> {
      const raw = await request<JsonValue>(
        `/graph/api/ruler/grafana/api/v1/rules/${encodeURIComponent(folderUid)}`,
        { method: "GET" }
      );
      return flattenRulerGroupsFromResponse(raw);
    },

    async postBatchedExprRulerGroup(folderUid: string, body: JsonObj): Promise<void> {
      await request(`/graph/api/ruler/grafana/api/v1/rules/${folderUid}`, {
        method: "POST",
        body,
      });
    },

    async deleteRulerRuleGroup(folderUid: string, ruleGroupName: string): Promise<void> {
      const encGroup = encodeURIComponent(ruleGroupName);
      await request(`/graph/api/ruler/grafana/api/v1/rules/${folderUid}/${encGroup}`, {
        method: "DELETE",
        okStatuses: new Set([404, 202, 200]),
      });
    },

    async listProvisioningAlertRules(): Promise<JsonObj[] | null> {
      for (const path of ["/graph/api/v1/provisioning/alert-rules", "/graph/api/alerting/provisioning/alert-rules"]) {
        try {
          const raw = await request<JsonValue>(path, { method: "GET" });
          const list = provisioningAlertRulesFromResponse(raw);
          if (list) return list;
        } catch {
          /* try next path */
        }
      }
      return null;
    },

    async deleteProvisioningAlertRuleByUid(uid: string): Promise<void> {
      const enc = encodeURIComponent(uid);
      await request(`/graph/api/v1/provisioning/alert-rules/${enc}`, {
        method: "DELETE",
        okStatuses: new Set([404, 200, 202]),
      });
    },

    async createAlertingRule(payload: JsonObj): Promise<void> {
      await request("/v1/alerting/rules", { method: "POST", body: payload });
    },
  };
}
