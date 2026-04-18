import type { Obj } from "./types";

/** True when PXC CR `status.state` is the string `ready` (same semantics as `getClusterReady`). */
export function isPxcClusterReadyBody(body: Obj | null): boolean {
  if (!body) return false;
  const status = body.status as Obj | undefined;
  const state = typeof status?.state === "string" ? status.state : "";
  return state === "ready";
}
