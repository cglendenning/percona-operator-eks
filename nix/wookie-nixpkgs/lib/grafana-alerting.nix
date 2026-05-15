# Helpers for Grafana unified-alerting file provisioning (Helm chart `alerting:` values).
{ lib }:

let
  ruleUid =
    { title, expr }:
    let
      h = builtins.hashString "sha256" (title + ":" + expr);
    in
    "sw-" + builtins.substring 0 32 h;

  prometheusQueryStep =
    { datasourceUid, expr }:
    {
      refId = "A";
      relativeTimeRange = {
        from = 600;
        to = 0;
      };
      datasourceUid = datasourceUid;
      model = {
        datasource = {
          type = "prometheus";
          uid = datasourceUid;
        };
        expr = expr;
        refId = "A";
        instant = false;
        range = true;
        intervalMs = 1000;
        maxDataPoints = 43200;
        editorMode = "code";
      };
    };

  reduceLastStep = {
    refId = "B";
    datasourceUid = "__expr__";
    model = {
      type = "reduce";
      refId = "B";
      datasource = {
        type = "__expr__";
        uid = "__expr__";
      };
      expression = "A";
      reducer = "last";
      settings = {
        mode = "dropNN";
      };
    };
  };

  # PromQL returns a percentage (0–100); alert when the last value is below `threshold`.
  promqlPercentBelowRule =
    {
      title,
      percentExpr,
      threshold,
      for ? "5m",
      datasourceUid,
      noDataState ? "OK",
      execErrState ? "Alerting",
      labels ? { },
      annotations ? { },
    }:
    {
      uid = ruleUid { title = title; expr = percentExpr + "<" + toString threshold; };
      inherit title;
      condition = "C";
      data = [
        (prometheusQueryStep {
          inherit datasourceUid;
          expr = percentExpr;
        })
        reduceLastStep
        {
          refId = "C";
          datasourceUid = "__expr__";
          model = {
            type = "threshold";
            refId = "C";
            datasource = {
              type = "__expr__";
              uid = "__expr__";
            };
            expression = "B";
            conditions = [
              {
                evaluator = {
                  type = "lt";
                  params = [ threshold ];
                };
                operator = {
                  type = "and";
                };
                reducer = {
                  type = "last";
                  params = [ ];
                };
              }
            ];
          };
        }
      ];
      noDataState = noDataState;
      execErrState = execErrState;
      "for" = for;
      inherit labels annotations;
      isPaused = false;
    };

in
{
  inherit promqlPercentBelowRule ruleUid;
}
