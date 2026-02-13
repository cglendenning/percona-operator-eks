kubectl create namespace wookie-restore 2>/dev/null || true

kubectl -n wookie-restore apply -f - <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: pxc-auto-restore-controller
spec:
  serviceAccountName: pxc-auto-restore-sa
  restartPolicy: Always
  containers:
    - name: controller
      image: pxc-auto-restore-controller:local
      imagePullPolicy: IfNotPresent
      env:
        - name: SOURCE_NS
          value: source-namespace
        - name: DEST_NS
          value: wookie-restore
        - name: DEST_PXC_CLUSTER
          value: cluster1
        - name: DEST_STORAGE_NAME
          value: s3-us-west
        - name: TRACKING_CM
          value: pxc-restore-tracker
        - name: SLEEP_SECONDS
          value: "60"
        - name: S3_CREDENTIALS_SECRET
          value: s3-credentials
        - name: S3_REGION
          value: us-east-1
        - name: S3_ENDPOINT_URL
          value: https://s3.us-east-1.amazonaws.com
        # Optional if your CRD version is not v1:
        # - name: PXC_API_VERSION
        #   value: "v1"
YAML

