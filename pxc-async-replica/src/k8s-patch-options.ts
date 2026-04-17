import { HttpMethod } from "@kubernetes/client-node/dist/gen/http/http.js";
import type { PromiseMiddleware } from "@kubernetes/client-node/dist/gen/middleware.js";
import { PromiseMiddlewareWrapper } from "@kubernetes/client-node/dist/gen/middleware.js";

/**
 * The OpenAPI-generated client picks `application/json-patch+json` before merge/strategic
 * when multiple patch media types are allowed. Our bodies are merge/strategic-shaped JSON objects.
 */
const mergePatchFix: PromiseMiddleware = {
  pre: async (ctx) => {
    if (ctx.getHttpMethod() !== HttpMethod.PATCH) return ctx;
    const url = ctx.getUrl();
    if (url.includes("/apis/pxc.percona.com/") && url.includes("/perconaxtradbclusters/")) {
      ctx.setHeaderParam("Content-Type", "application/merge-patch+json");
      return ctx;
    }
    if (url.includes("/apis/apps/v1/") && (url.includes("/statefulsets/") || url.includes("/deployments/"))) {
      ctx.setHeaderParam("Content-Type", "application/strategic-merge-patch+json");
      return ctx;
    }
    return ctx;
  },
  post: async (c) => c,
};

/** Prepend so default auth / transport middleware from the client config stays intact. */
export const K8S_PATCH_CONTENT_TYPE_OPTIONS = {
  middleware: [new PromiseMiddlewareWrapper(mergePatchFix)],
  middlewareMergeStrategy: "prepend" as const,
};
