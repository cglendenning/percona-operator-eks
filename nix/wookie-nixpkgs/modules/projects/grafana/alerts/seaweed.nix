# SeaweedFS volume alerts (domain definitions only).
#
# SeaweedFS_volumeServer_resource labels (see seaweedfs/weed/storage/disk_location.go):
#   type="all"   total bytes on the volume dir
#   type="used"  bytes used by volumes
#   type="free"  filesystem free bytes
#   type="avail" bytes Seaweed considers available (free minus minFreeSpace reserve)
#
# Alert on percent available: (avail / all) * 100, same thresholds as PXC disk usage.
{ }:
let
  data1 = "/data1";

  # `type` differs on numerator vs denominator; PromQL needs ignoring(type) or no match.
  percentFree =
    mount:
    ''
      (
        SeaweedFS_volumeServer_resource{name="${mount}",type="free"}
        / ignoring(type) clamp_min(SeaweedFS_volumeServer_resource{name="${mount}",type="all"}, 1)
      ) * 100'';

  percentAvail =
    mount:
    ''
      (
        SeaweedFS_volumeServer_resource{name="${mount}",type="avail"}
        / ignoring(type) clamp_min(SeaweedFS_volumeServer_resource{name="${mount}",type="all"}, 1)
      ) * 100'';

in
[
  {
    title = "SeaweedFS Volume Data1 Available Space Warning";
    percentExpr = percentAvail data1;
    threshold = 30;
    for = "10m";
    noDataState = "OK";
    labels = {
      source = "wookie";
      severity = "warning";
    };
  }
  {
    title = "SeaweedFS Volume Data1 Available Space Critical";
    percentExpr = percentAvail data1;
    threshold = 20;
    for = "5m";
    noDataState = "OK";
    labels = {
      source = "wookie";
      severity = "critical";
    };
  }
]
