import { asString } from "./primitives";

export type Obj = Record<string, unknown>;

export type SourceEntry = { host: string; port: number; weight: number };

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
