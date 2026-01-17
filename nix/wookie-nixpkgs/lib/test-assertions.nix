{ lib, pkgs }:

let
  # Define assertion types
  mkAssertion = { id, description, command, expectedPattern ? null }:
    {
      inherit id description command expectedPattern;
      type = if expectedPattern != null then "pattern-match" else "exit-code";
    };

  # Cluster contexts
  ctxA = "k3d-cluster-a";
  ctxB = "k3d-cluster-b";

in rec {
  # Group assertions by category
  infrastructure = [
    (mkAssertion {
      id = "cluster-a-accessible";
      description = "Cluster A is accessible";
      command = "kubectl cluster-info --context=${ctxA}";
    })
    (mkAssertion {
      id = "cluster-b-accessible";
      description = "Cluster B is accessible";
      command = "kubectl cluster-info --context=${ctxB}";
    })
    (mkAssertion {
      id = "same-docker-network";
      description = "Cluster A and B are on same Docker network";
      command = "docker network inspect k3d-multicluster | grep -E 'k3d-cluster-[ab]-server-0' | wc -l | tr -d ' '";
      expectedPattern = "^[2-9]";
    })
  ];

  controlPlane = [
    (mkAssertion {
      id = "istiod-cluster-a";
      description = "Istiod is running in Cluster A";
      command = ''kubectl get deployment istiod -n istio-system --context=${ctxA} -o jsonpath='{.status.availableReplicas}' | grep -q '^[1-9]' '';
    })
    (mkAssertion {
      id = "istiod-cluster-b";
      description = "Istiod is running in Cluster B";
      command = ''kubectl get deployment istiod -n istio-system --context=${ctxB} -o jsonpath='{.status.availableReplicas}' | grep -q '^[1-9]' '';
    })
    (mkAssertion {
      id = "eastwest-gateway-a";
      description = "East-west gateway is running in Cluster A";
      command = ''kubectl get deployment istio-eastwestgateway -n istio-system --context=${ctxA} -o jsonpath='{.status.availableReplicas}' | grep -q '^[1-9]' '';
    })
    (mkAssertion {
      id = "eastwest-gateway-b";
      description = "East-west gateway is running in Cluster B";
      command = ''kubectl get deployment istio-eastwestgateway -n istio-system --context=${ctxB} -o jsonpath='{.status.availableReplicas}' | grep -q '^[1-9]' '';
    })
    (mkAssertion {
      id = "eastwest-lb-a";
      description = "East-west gateway has LoadBalancer service in Cluster A";
      command = ''kubectl get svc istio-eastwestgateway -n istio-system --context=${ctxA} -o jsonpath='{.spec.type}' | grep -q 'LoadBalancer' '';
    })
    (mkAssertion {
      id = "eastwest-lb-b";
      description = "East-west gateway has LoadBalancer service in Cluster B";
      command = ''kubectl get svc istio-eastwestgateway -n istio-system --context=${ctxB} -o jsonpath='{.spec.type}' | grep -q 'LoadBalancer' '';
    })
  ];

  mtls = [
    (mkAssertion {
      id = "cacerts-cluster-a";
      description = "cacerts secret exists in Cluster A";
      command = "kubectl get secret cacerts -n istio-system --context=${ctxA}";
    })
    (mkAssertion {
      id = "cacerts-cluster-b";
      description = "cacerts secret exists in Cluster B";
      command = "kubectl get secret cacerts -n istio-system --context=${ctxB}";
    })
    (mkAssertion {
      id = "root-cert-a";
      description = "cacerts has root-cert.pem in Cluster A";
      command = ''kubectl get secret cacerts -n istio-system --context=${ctxA} -o jsonpath='{.data.root-cert\.pem}' | grep -q '.' '';
    })
    (mkAssertion {
      id = "root-cert-b";
      description = "cacerts has root-cert.pem in Cluster B";
      command = ''kubectl get secret cacerts -n istio-system --context=${ctxB} -o jsonpath='{.data.root-cert\.pem}' | grep -q '.' '';
    })
    (mkAssertion {
      id = "root-cert-match";
      description = "Both clusters have identical root CA";
      command = ''
        ROOT_A=$(kubectl get secret cacerts -n istio-system --context=${ctxA} -o jsonpath='{.data.root-cert\.pem}' 2>/dev/null)
        ROOT_B=$(kubectl get secret cacerts -n istio-system --context=${ctxB} -o jsonpath='{.data.root-cert\.pem}' 2>/dev/null)
        [ "$ROOT_A" = "$ROOT_B" ]
      '';
    })
  ];

  multiClusterConfig = [
    (mkAssertion {
      id = "network-label-a";
      description = "Network label set on istio-system namespace in Cluster A";
      command = ''kubectl get namespace istio-system --context=${ctxA} -o jsonpath='{.metadata.labels.topology\.istio\.io/network}' | grep -q '.' '';
    })
    (mkAssertion {
      id = "network-label-b";
      description = "Network label set on istio-system namespace in Cluster B";
      command = ''kubectl get namespace istio-system --context=${ctxB} -o jsonpath='{.metadata.labels.topology\.istio\.io/network}' | grep -q '.' '';
    })
    (mkAssertion {
      id = "remote-secret-a";
      description = "Remote secret exists in Cluster A for Cluster B access";
      command = "kubectl get secret -n istio-system --context=${ctxA} | grep -q 'istio-remote-secret'";
    })
    (mkAssertion {
      id = "remote-secret-b";
      description = "Remote secret exists in Cluster B for Cluster A access";
      command = "kubectl get secret -n istio-system --context=${ctxB} | grep -q 'istio-remote-secret'";
    })
    (mkAssertion {
      id = "mesh-networks-a";
      description = "Istiod in Cluster A has meshNetworks configured";
      command = "kubectl get configmap istio -n istio-system --context=${ctxA} -o jsonpath='{.data.mesh}'";
      expectedPattern = "meshNetworks";
    })
    (mkAssertion {
      id = "mesh-networks-b";
      description = "Istiod in Cluster B has meshNetworks configured";
      command = "kubectl get configmap istio -n istio-system --context=${ctxB} -o jsonpath='{.data.mesh}'";
      expectedPattern = "meshNetworks";
    })
  ];

  application = [
    (mkAssertion {
      id = "helloworld-deployment";
      description = "Helloworld app is deployed in Cluster A";
      command = "kubectl get deployment helloworld-v1 -n demo --context=${ctxA}";
    })
    (mkAssertion {
      id = "helloworld-pods-running";
      description = "Helloworld pods are running in Cluster A";
      command = ''
        # Wait for at least one pod to be ready
        kubectl wait --for=condition=ready pod -l app=helloworld -n demo --context=${ctxA} --timeout=30s >/dev/null 2>&1 || true
        # Then check if any are running
        kubectl get pods -n demo --context=${ctxA} -l app=helloworld -o jsonpath='{range .items[*]}{.status.phase}{"\n"}{end}' | grep -q 'Running'
      '';
    })
    (mkAssertion {
      id = "helloworld-service";
      description = "Helloworld service exists in Cluster A";
      command = "kubectl get service helloworld -n demo --context=${ctxA}";
    })
    (mkAssertion {
      id = "helloworld-sidecar";
      description = "Helloworld pods have sidecar injected in Cluster A";
      command = ''kubectl get pod -n demo --context=${ctxA} -l app=helloworld -o jsonpath='{.items[0].spec.containers[*].name}' | grep -q 'istio-proxy' '';
    })
  ];

  connectivity = [
    (mkAssertion {
      id = "test-pod-exists";
      description = "Test pod exists in Cluster B";
      command = "kubectl get pod test-pod -n wookie-dr --context=${ctxB}";
    })
    (mkAssertion {
      id = "test-pod-sidecar";
      description = "Test pod has sidecar injected in Cluster B";
      command = ''kubectl get pod test-pod -n wookie-dr --context=${ctxB} -o jsonpath='{.spec.containers[*].name}' | grep -q 'istio-proxy' '';
    })
    (mkAssertion {
      id = "istiod-sees-remote-endpoints";
      description = "Istiod in Cluster B sees Cluster A endpoints";
      command = "kubectl exec -n istio-system deployment/istiod --context=${ctxB} -- curl -s localhost:15014/debug/endpointz";
      expectedPattern = "k3d-cluster-a";
    })
    (mkAssertion {
      id = "envoy-has-helloworld-endpoints";
      description = "Envoy sidecar in Cluster B has endpoints for helloworld service";
      command = "kubectl exec test-pod -n wookie-dr -c istio-proxy --context=${ctxB} -- pilot-agent request GET clusters";
      expectedPattern = "helloworld.demo.svc.cluster.local";
    })
  ];

  endToEnd = [
    (mkAssertion {
      id = "cross-cluster-http";
      description = "HTTP request from Cluster B to helloworld in Cluster A";
      command = "kubectl exec test-pod -n wookie-dr --context=${ctxB} -- curl -s --max-time 10 http://helloworld.demo.svc.cluster.local:5000/hello";
      expectedPattern = "Hello version";
    })
    (mkAssertion {
      id = "mtls-enabled";
      description = "mTLS is enabled between services";
      command = "kubectl exec test-pod -n wookie-dr -c istio-proxy --context=${ctxB} -- curl -s localhost:15000/config_dump";
      expectedPattern = "MUTUAL_TLS";
    })
  ];

  dynamicDiscovery = [
    (mkAssertion {
      id = "create-discovery-namespace";
      description = "Create test namespace in Cluster A with Istio injection";
      command = ''kubectl create namespace automatic-discovery-test --context=${ctxA} --dry-run=client -o yaml | kubectl apply --context=${ctxA} -f - && kubectl label namespace automatic-discovery-test istio-injection=enabled --context=${ctxA} --overwrite'';
    })
    (mkAssertion {
      id = "deploy-nginx-service";
      description = "Deploy nginx service in new namespace";
      command = ''
        cat <<EOF | kubectl apply --context=${ctxA} -f -
apiVersion: v1
kind: Service
metadata:
  name: nginx-test
  namespace: automatic-discovery-test
spec:
  ports:
  - port: 80
    name: http
  selector:
    app: nginx-test
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-test
  namespace: automatic-discovery-test
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nginx-test
  template:
    metadata:
      labels:
        app: nginx-test
    spec:
      containers:
      - name: nginx
        image: nginx:alpine
        ports:
        - containerPort: 80
EOF
      '';
    })
    (mkAssertion {
      id = "wait-nginx-ready";
      description = "Wait for nginx pod to be ready";
      command = "kubectl wait --for=condition=ready pod -l app=nginx-test -n automatic-discovery-test --context=${ctxA} --timeout=90s";
    })
    (mkAssertion {
      id = "nginx-has-sidecar";
      description = "Nginx pod has Istio sidecar injected";
      command = ''kubectl get pod -n automatic-discovery-test --context=${ctxA} -l app=nginx-test -o jsonpath='{.items[0].spec.containers[*].name}' | grep -q 'istio-proxy' '';
    })
    (mkAssertion {
      id = "cluster-b-discovers-nginx";
      description = "Cluster B Istiod discovers new nginx service endpoints";
      command = ''
        # Give Istiod time to discover the new service
        sleep 5
        kubectl exec -n istio-system deployment/istiod --context=${ctxB} -- curl -s localhost:15014/debug/endpointz | grep -q 'nginx-test.automatic-discovery-test'
      '';
    })
    (mkAssertion {
      id = "cluster-b-envoy-sees-nginx";
      description = "Cluster B test pod Envoy has nginx endpoints";
      command = ''
        sleep 3
        kubectl exec test-pod -n wookie-dr -c istio-proxy --context=${ctxB} -- pilot-agent request GET clusters | grep -q 'nginx-test.automatic-discovery-test.svc.cluster.local'
      '';
    })
    (mkAssertion {
      id = "cross-cluster-nginx-http";
      description = "HTTP request from Cluster B to nginx in Cluster A";
      command = "kubectl exec test-pod -n wookie-dr --context=${ctxB} -- curl -s --max-time 10 http://nginx-test.automatic-discovery-test.svc.cluster.local";
      expectedPattern = "Welcome to nginx";
    })
    (mkAssertion {
      id = "cleanup-discovery-namespace";
      description = "Clean up automatic discovery test namespace";
      command = "kubectl delete namespace automatic-discovery-test --context=${ctxA} --ignore-not-found=true --timeout=60s";
    })
  ];

  cleanup = [
    (mkAssertion {
      id = "delete-test-pod";
      description = "Delete test pod from Cluster B";
      command = "kubectl delete pod test-pod -n wookie-dr --context=${ctxB} --ignore-not-found=true";
    })
    (mkAssertion {
      id = "verify-test-pod-gone";
      description = "Verify test pod is deleted";
      command = "! kubectl get pod test-pod -n wookie-dr --context=${ctxB} 2>/dev/null";
    })
  ];

  # All assertions grouped
  all = lib.flatten [
    infrastructure
    controlPlane
    mtls
    multiClusterConfig
    application
    connectivity
    endToEnd
    dynamicDiscovery
    cleanup
  ];

  # Category metadata
  categories = {
    infrastructure = { name = "INFRASTRUCTURE CHECKS"; assertions = infrastructure; };
    controlPlane = { name = "ISTIO CONTROL PLANE"; assertions = controlPlane; };
    mtls = { name = "mTLS CONFIGURATION"; assertions = mtls; };
    multiClusterConfig = { name = "MULTI-CLUSTER CONFIGURATION"; assertions = multiClusterConfig; };
    application = { name = "APPLICATION DEPLOYMENT"; assertions = application; };
    connectivity = { name = "CROSS-CLUSTER CONNECTIVITY"; assertions = connectivity; };
    endToEnd = { name = "END-TO-END CONNECTIVITY TEST"; assertions = endToEnd; };
    dynamicDiscovery = { name = "DYNAMIC SERVICE DISCOVERY"; assertions = dynamicDiscovery; };
    cleanup = { name = "CLEANUP"; assertions = cleanup; };
  };
}
