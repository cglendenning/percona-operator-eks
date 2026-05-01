import { asString } from "./primitives";

export type Obj = Record<string, unknown>;

export type SourceEntry = { host: string; port: number; weight: number };

/** `spec.pxc.replicationChannels[].configuration` (replica / `isSource: false` only). */
export type ReplicationChannelConnectConfig = {
  /** Number of times the replica retries a failed source connection (operator default 3). */
  sourceRetryCount: number;
  /** Seconds to wait between reconnection attempts (operator default 60). */
  sourceConnectRetry: number;
};

/** Recursively sort object keys so JSON comparison is order-insensitive. */
export function sortKeysDeep(val: unknown): unknown {
  if (val === null || val === undefined) return val;
  if (typeof val !== "object") return val;
  if (Array.isArray(val)) return val.map(sortKeysDeep);
  const obj = val as Record<string, unknown>;
  const out: Record<string, unknown> = {};
  for (const k of Object.keys(obj).sort()) {
    const v = obj[k];
    if (v !== undefined) {
      out[k] = sortKeysDeep(v);
    }
  }
  return out;
}

export function normalizeChannels(ch: unknown): string {
  if (!Array.isArray(ch)) return JSON.stringify(sortKeysDeep([]));
  const arr = ch as Obj[];
  const sorted: Obj[] = [...arr].map((c: Obj) => {
    const sources = Array.isArray(c.sourcesList) ? [...(c.sourcesList as Obj[])] : [];
    sources.sort((a, b) =>
      asString(a.host).localeCompare(asString(b.host))
    );
    return { ...c, sourcesList: sources } as Obj;
  });
  sorted.sort((a, b) => asString(a.name).localeCompare(asString(b.name)));
  return JSON.stringify(sortKeysDeep(sorted));
}

export function channelsMatchSpec(actual: unknown, expected: Obj[]): boolean {
  return normalizeChannels(actual) === normalizeChannels(expected);
}

export function buildDesiredChannels(
  channelName: string,
  sources: SourceEntry[],
  connectConfig?: ReplicationChannelConnectConfig
): Obj[] {
  const ch: Obj = {
    name: channelName,
    isSource: false,
    sourcesList: sources.map((s) => ({
      host: s.host,
      port: s.port,
      weight: s.weight,
    })),
  };
  if (connectConfig) {
    ch.configuration = {
      sourceRetryCount: connectConfig.sourceRetryCount,
      sourceConnectRetry: connectConfig.sourceConnectRetry,
    };
  }
  return [ch];
}

function parsePortOr(p: unknown, fallback: number): number {
  const n = typeof p === "number" ? p : typeof p === "string" ? parseInt(p, 10) : NaN;
  return Number.isFinite(n) && n > 0 && n <= 65535 ? n : fallback;
}

function parseWeightOr(w: unknown): number {
  const n = typeof w === "number" ? w : typeof w === "string" ? parseInt(w, 10) : NaN;
  return Number.isFinite(n) ? n : 100;
}

/**
 * Reads `spec.pxc.replicationChannels` for the named channel (live cluster spec).
 * Returns null if missing, wrong shape, or no usable sources.
 */
export function extractReplicationSourcesFromPxcBody(
  body: unknown,
  channelName: string,
  defaultPort: number
): SourceEntry[] | null {
  if (body === null || typeof body !== "object") return null;
  const spec = (body as Obj).spec;
  if (spec === null || typeof spec !== "object") return null;
  const pxc = (spec as Obj).pxc;
  if (pxc === null || typeof pxc !== "object") return null;
  const chans = (pxc as Obj).replicationChannels;
  if (!Array.isArray(chans)) return null;
  const want = channelName.trim();
  if (!want) return null;
  for (const ch of chans as Obj[]) {
    if (asString(ch.name) !== want) continue;
    const list = ch.sourcesList;
    if (!Array.isArray(list) || list.length === 0) return null;
    const out: SourceEntry[] = [];
    for (const s of list as Obj[]) {
      const host = asString(s.host).trim();
      if (!host) continue;
      out.push({
        host,
        port: parsePortOr(s.port, defaultPort),
        weight: parseWeightOr(s.weight),
      });
    }
    return out.length > 0 ? out : null;
  }
  return null;
}

/** Prefer highest weight, then lexicographically smallest host (deterministic). */
export function pickPreferredReplicationSource(sources: SourceEntry[]): SourceEntry {
  if (sources.length === 0) throw new Error("pickPreferredReplicationSource: empty sources");
  const sorted = [...sources].sort((a, b) => {
    if (b.weight !== a.weight) return b.weight - a.weight;
    return a.host.localeCompare(b.host);
  });
  return sorted[0]!;
}
