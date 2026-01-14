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

in {
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
      command = "docker network inspect k3d-multicluster";
      expectedPattern = "k3d-cluster-a-server-0.*k3d-cluster-b-server-0";
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
      command = "kubectl get pods -n demo --context=${ctxA} -l app=helloworld --field-selector=status.phase=Running";
      expectedPattern = "helloworld";
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
      command = "kubectl get pod test-pod -n demo --context=${ctxB}";
    })
    (mkAssertion {
      id = "test-pod-sidecar";
      description = "Test pod has sidecar injected in Cluster B";
      command = ''kubectl get pod test-pod -n demo --context=${ctxB} -o jsonpath='{.spec.containers[*].name}' | grep -q 'istio-proxy' '';
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
      command = "kubectl exec test-pod -n demo -c istio-proxy --context=${ctxB} -- pilot-agent request GET clusters";
      expectedPattern = "helloworld.demo.svc.cluster.local";
    })
  ];

  endToEnd = [
    (mkAssertion {
      id = "cross-cluster-http";
      description = "HTTP request from Cluster B to helloworld in Cluster A";
      command = "kubectl exec test-pod -n demo --context=${ctxB} -- curl -s --max-time 10 http://helloworld.demo.svc.cluster.local:5000/hello";
      expectedPattern = "Hello version";
    })
    (mkAssertion {
      id = "mtls-enabled";
      description = "mTLS is enabled between services";
      command = "kubectl exec test-pod -n demo -c istio-proxy --context=${ctxB} -- curl -s localhost:15000/config_dump";
      expectedPattern = "tlsMode.*ISTIO_MUTUAL";
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
  };
}
