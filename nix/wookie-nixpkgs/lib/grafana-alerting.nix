# Helpers for Grafana unified-alerting file provisioning (Helm chart `alerting:` values).
{ lib }:

let
  ruleUid =
    { title, expr }:
    let
      h = builtins.hashString "sha256" (title + ":" + expr);
    in
    "sw-" + builtins.substring 0 32 h;

  # Boolean PromQL (non-zero when firing) evaluated via Prometheus instant query + threshold > 0.
  promqlBooleanRule =
    {
      title,
      expr,
      for ? "5m",
      datasourceUid,
      noDataState ? "OK",
      execErrState ? "Alerting",
      labels ? { },
      annotations ? { },
    }:
    {
      uid = ruleUid { inherit title expr; };
      inherit title;
      condition = "C";
      data = [
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
            instant = true;
            range = false;
            intervalMs = 1000;
            maxDataPoints = 43200;
            editorMode = "code";
          };
        }
        {
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
        }
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
                  type = "gt";
                  params = [ 0 ];
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
  inherit promqlBooleanRule ruleUid;
}
