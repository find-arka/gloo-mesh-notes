#!/bin/sh
##
# Usage:
# ./setup-multicluster-gme-k3d.sh [num_workload_clusters] [gme_version]
# Optional Parameters:
# 1. Number of workload clusters to create and connect in the mesh (default 2)
# 2. Gloo Mesh Enterprise version (default 2.6.6)
##

NUMBER_OF_WORKLOAD_CLUSTERS=$1
GLOO_MESH_ENTERPRISE_VERSION=$2

if [ -z "${NUMBER_OF_WORKLOAD_CLUSTERS}" ]; then
  # Set the default value
  NUMBER_OF_WORKLOAD_CLUSTERS=2
fi

if [ -z "${GLOO_MESH_ENTERPRISE_VERSION}" ]; then
  # Set the default value
  GLOO_MESH_ENTERPRISE_VERSION=2.6.6
fi

echo;echo;echo "[DEBUG] Running tests with the following parameters-"
echo "[DEBUG] Number of workload clusters     : ${NUMBER_OF_WORKLOAD_CLUSTERS}"
echo "[DEBUG] Gloo Mesh Enterprise version    : ${GLOO_MESH_ENTERPRISE_VERSION}"
echo;echo;echo;

sleep 3

# creating a bridge network so that all the clusters share the same network and intercluster comms are possible
docker network create --driver bridge k3d-gme-multicluster-network

k3d cluster create gloo-mgmt-cluster --network k3d-gme-multicluster-network
MGMT_CONTEXT=k3d-gloo-mgmt-cluster

# wait for cluster to be ready before installing GME mgmt server
kubectl --context $MGMT_CONTEXT -n kube-system rollout status deploy/coredns
kubectl --context $MGMT_CONTEXT -n kube-system rollout status deploy/local-path-provisioner
kubectl --context $MGMT_CONTEXT -n kube-system rollout status deploy/metrics-server
kubectl --context $MGMT_CONTEXT -n kube-system rollout status deploy/traefik

# update to get the latest charts
helm repo update

kubectl --context "${MGMT_CONTEXT}" create ns gloo-mesh
helm upgrade -i gloo-platform-crds gloo-platform/gloo-platform-crds \
  --version="${GLOO_MESH_ENTERPRISE_VERSION}" \
  --kube-context "${MGMT_CONTEXT}" \
  --namespace=gloo-mesh --wait

helm upgrade -i gloo-platform gloo-platform/gloo-platform \
  --version="${GLOO_MESH_ENTERPRISE_VERSION}" \
  --namespace=gloo-mesh \
  --kube-context "${MGMT_CONTEXT}" \
  --wait \
  --values - <<EOF
common:
  # Name of the cluster. Be sure to modify this value to match your cluster's name.
  cluster: "${MGMT_CONTEXT}"
licensing:
  glooMeshLicenseKey: "${GLOO_PLATFORM_LICENSE_KEY}"
# Configuration for the Gloo management server.
glooMgmtServer:
  enabled: true
  serviceType: LoadBalancer
## uncomment to enable the gloo insights engine UI
# glooInsightsEngine:
#   enabled: true
# Configuration for the Gloo UI.
glooUi:
  enabled: true
# Gloo Platform Redis configuration options.
redis:
  deployment:
    enabled: true
# Helm values for configuring Prometheus. See the [Prometheus Helm chart](https://github.com/prometheus-community/helm-charts/blob/main/charts/prometheus/values.yaml) for the complete set of values.
prometheus:
  enabled: true
telemetryCollector:
  enabled: true
# OTLP collector for workload cluster collectors
telemetryGateway:
  enabled: true
  service:
    type: LoadBalancer
EOF

## Adds RootTrustPolicy for shared root cert setup for Istio in different workload clusters
kubectl apply --context "${MGMT_CONTEXT}" -f - <<EOF
apiVersion: admin.gloo.solo.io/v2
kind: RootTrustPolicy
metadata:
  name: root-trust-policy
  namespace: gloo-mesh
spec:
  config:
    intermediateCertOptions:
      secretRotationGracePeriodRatio: 0.1
      ttlDays: 1
    mgmtServerCa:
      generated:
        ttlDays: 730
EOF

kubectl get secret relay-root-tls-secret --context $MGMT_CONTEXT -n gloo-mesh -o jsonpath='{.data.ca\.crt}' | base64 -d > ca.crt
kubectl get secret relay-identity-token-secret --context $MGMT_CONTEXT -n gloo-mesh -o jsonpath='{.data.token}' | base64 -d > token

##
# Telemetry Gateway and Mgmt server service addresses
# To be used as helm overrides from agents
##
GLOO_PLATFORM_SERVER_LB=$(kubectl --context ${MGMT_CONTEXT} -n gloo-mesh get svc gloo-mesh-mgmt-server -o jsonpath='{.status.loadBalancer.ingress[0].*}')
GLOO_PLATFORM_SERVER_ADDRESS="${GLOO_PLATFORM_SERVER_LB}":$(kubectl get svc gloo-mesh-mgmt-server --context ${MGMT_CONTEXT} -n gloo-mesh -o jsonpath='{.spec.ports[?(@.name=="grpc")].port}')
GLOO_TELEMETRY_GATEWAY_LB=$(kubectl --context ${MGMT_CONTEXT} -n gloo-mesh get svc gloo-telemetry-gateway -o jsonpath='{.status.loadBalancer.ingress[0].*}')
GLOO_TELEMETRY_GATEWAY="${GLOO_TELEMETRY_GATEWAY_LB}":$(kubectl get svc gloo-telemetry-gateway --context ${MGMT_CONTEXT} -n gloo-mesh -o jsonpath='{.spec.ports[?(@.name=="otlp")].port}')

for ((i = 1; i <= NUMBER_OF_WORKLOAD_CLUSTERS; i++))
do
    k3d cluster create "workload-cluster${i}" --network k3d-gme-multicluster-network
    CURRENT_CONTEXT="k3d-workload-cluster${i}"
    
    # wait for cluster to be ready before installing GME agents
    kubectl --context $CURRENT_CONTEXT -n kube-system rollout status deploy/coredns
    kubectl --context $CURRENT_CONTEXT -n kube-system rollout status deploy/local-path-provisioner
    kubectl --context $CURRENT_CONTEXT -n kube-system rollout status deploy/metrics-server
    kubectl --context $CURRENT_CONTEXT -n kube-system rollout status deploy/traefik


    kubectl apply --context "${MGMT_CONTEXT}" -f - <<EOF
apiVersion: admin.gloo.solo.io/v2
kind: KubernetesCluster
metadata:
  name: "${CURRENT_CONTEXT}"
  namespace: gloo-mesh
spec:
  clusterDomain: cluster.local
EOF

    kubectl create namespace gloo-mesh --context "${CURRENT_CONTEXT}"
    kubectl create secret generic relay-root-tls-secret --from-file ca.crt=ca.crt --context "${CURRENT_CONTEXT}" -n gloo-mesh
    kubectl create secret generic relay-identity-token-secret --from-file token=token --context "${CURRENT_CONTEXT}" -n gloo-mesh


    helm upgrade -i gloo-platform-crds gloo-platform/gloo-platform-crds \
    --version="${GLOO_MESH_ENTERPRISE_VERSION}" \
    --namespace=gloo-mesh \
    --kube-context "${CURRENT_CONTEXT}" --wait

    helm upgrade -i gloo-agent gloo-platform/gloo-platform \
    --version="${GLOO_MESH_ENTERPRISE_VERSION}" \
    --namespace gloo-mesh \
    --kube-context "${CURRENT_CONTEXT}" \
    --values - << EOF
# Configuration for the Gloo agent.
common:
  cluster: "${CURRENT_CONTEXT}"
glooAgent:
  enabled: true
  relay:
    serverAddress: "${GLOO_PLATFORM_SERVER_ADDRESS}"
## uncomment to enable the insights analyzer sidecar to the agent
# glooAnalyzer:
#   enabled: true
# Configuration for the Gloo Platform Telemetry Collector. See the [OpenTelemetry Helm chart](https://github.com/open-telemetry/opentelemetry-helm-charts/blob/main/charts/opentelemetry-collector/values.yaml) for the complete set of values.
telemetryCollector:
  enabled: true
  config:
    exporters:
      otlp:
        endpoint: "${GLOO_TELEMETRY_GATEWAY}"
EOF

done

# Waiting for the gloo-mesh-agent Deployments to be ready before running the "meshctl check" to get the final status
for ((i = 1; i <= NUMBER_OF_WORKLOAD_CLUSTERS; i++))
do
  echo;echo "Cluster ${i}:"
  kubectl --context "k3d-workload-cluster${i}" -n gloo-mesh rollout status deploy/gloo-mesh-agent
done

echo
echo "#############################################################################"
echo "---- meshctl check output to validate the connectivity ----"
echo "#############################################################################"
echo
meshctl check --kubecontext $MGMT_CONTEXT | grep -A 50 "Mgmt server connectivity to workload agents"

# cleanup
rm ca.crt token


echo
echo "#############################################################################"
echo "---- Installing istio ----"
echo "#############################################################################"
echo
for ((i = 1; i <= NUMBER_OF_WORKLOAD_CLUSTERS; i++))
do
  CURRENT_CONTEXT="k3d-workload-cluster${i}"

kubectl --context "${MGMT_CONTEXT}" apply -f - <<EOF
apiVersion: admin.gloo.solo.io/v2
kind: IstioLifecycleManager
metadata:
  name: "istio-control-plane-${CURRENT_CONTEXT}"
  namespace: gloo-mesh
spec:
  installations:
      # The revision for this installation, such as 1-23
    - revision: 1-23
      # Names of image pull secrets to use to deploy the Istio controller.
      # TODO put the imagePullSecrets value
      #istioController:
      #  imagePullSecrets: []
      # List all workload clusters to install Istio into
      clusters:
      # TODO replace with cluster name
      - name: "${CURRENT_CONTEXT}"
        # If set to true, the spec for this revision is applied in the cluster
        defaultRevision: true
      # When set to true, the lifecycle manager allows you to perform in-place upgrades by skipping checks that are required for canary upgrades
      skipUpgradeValidation: true
      istioOperatorSpec:
        # Only the control plane components are installed
        # (https://istio.io/latest/docs/setup/additional-setup/config-profiles/)
        profile: minimal
        # Solo.io Istio distribution repository; required for Gloo Istio.
        # You get the repo key from your Solo Account Representative.
        # TODO
        hub: us-docker.pkg.dev/gloo-mesh/istio-workshops
        # Any Solo.io Gloo Istio tag
        tag: 1.23.2-solo
        namespace: istio-system
        # Mesh configuration
        meshConfig:
          # Enable access logging only if using.
          accessLogFile: /dev/stdout
          # Encoding for the proxy access log (TEXT or JSON). Default value is TEXT.
          accessLogEncoding: JSON
          # Enable span tracing only if using.
          enableTracing: true
          defaultConfig:
            # Wait for the istio-proxy to start before starting application pods
            holdApplicationUntilProxyStarts: true
            proxyMetadata:
              # Enable Istio agent to handle DNS requests for known hosts
              # Unknown hosts are automatically resolved using upstream DNS servers
              # in resolv.conf (for proxy-dns)
              ISTIO_META_DNS_CAPTURE: "true"
              # Enable automatic address allocation (for proxy-dns)
              ISTIO_META_DNS_AUTO_ALLOCATE: "true"
          # Set the default behavior of the sidecar for handling outbound traffic
          # from the application
          outboundTrafficPolicy:
            mode: REGISTRY_ONLY
          # The administrative root namespace for Istio configuration
          rootNamespace: istio-system
        # Traffic management
        values:
          global:
            # ImagePullSecrets for control plane ServiceAccount, list of secrets in the same namespace
            # to use for pulling any images in pods that reference this ServiceAccount.
            # Must be set for any cluster configured with private docker registry.
            # imagePullSecrets:
            # - private-registry-key
            meshID: gloo-mesh
            # TODO replace with cluster name
            network: "${CURRENT_CONTEXT}"
            multiCluster:
              # TODO replace with cluster name
              clusterName: "${CURRENT_CONTEXT}"
        # Traffic management
        components:
          pilot:
            k8s:
              env:
              # Disable selecting workload entries for local service routing.
              # Required for Gloo VirtualDestinaton functionality.
              - name: PILOT_ENABLE_K8S_SELECT_WORKLOAD_ENTRIES
                value: "false"
              # Reload cacerts when cert-manager changes it
              - name: AUTO_RELOAD_PLUGIN_CERTS
                value: "true"
          # # Uncomment following if using the istio-cni plugin				
          # # deploy istio-cni-node DaemonSet into the cluster. More info on the plugin-
          # # https://istio.io/latest/docs/setup/additional-setup/cni/
          # cni:
          #   enabled: true
          #   hub: us-docker.pkg.dev/gloo-mesh/istio-workshops
          #   tag: 1.23.2-solo
          #   namespace: kube-system
EOF
done

for ((i = 1; i <= NUMBER_OF_WORKLOAD_CLUSTERS; i++))
do
  CURRENT_CONTEXT="k3d-workload-cluster${i}"
  sleep 5
  kubectl --context $CURRENT_CONTEXT -n gm-iop-1-23 rollout status deploy/istio-operator-1-23
done

for ((i = 1; i <= NUMBER_OF_WORKLOAD_CLUSTERS; i++))
do
  CURRENT_CONTEXT="k3d-workload-cluster${i}"
  sleep 5
  kubectl --context $CURRENT_CONTEXT -n istio-system rollout status deploy/istiod-1-23
done

echo
echo "#############################################################################"
echo "---- Deploy sample apps in the service mesh in workload clusters ----"
echo "#############################################################################"
echo
CLIENT_APP_NAMESPACE=client-app-namespace
SERVER_APP_NAMESPACE=server-app-namespace
for ((i = 1; i <= NUMBER_OF_WORKLOAD_CLUSTERS; i++))
do
  CURRENT_CONTEXT="k3d-workload-cluster${i}"
  kubectl --context ${CURRENT_CONTEXT} create ns $CLIENT_APP_NAMESPACE
  kubectl --context ${CURRENT_CONTEXT} label namespace $CLIENT_APP_NAMESPACE istio-injection=enabled
  kubectl --context ${CURRENT_CONTEXT} create ns $SERVER_APP_NAMESPACE
  kubectl --context ${CURRENT_CONTEXT} label namespace $SERVER_APP_NAMESPACE istio-injection=enabled
  SUFFIX=""
  
  for NS in "${CLIENT_APP_NAMESPACE}" "${SERVER_APP_NAMESPACE}" "default"
  do
    if [[ "$NS" == *"default"* ]]; then
      SUFFIX="outside-mesh"
    else
      SUFFIX="${NS}"
    fi
    kubectl --context ${CURRENT_CONTEXT} --namespace "${NS}" apply -f - << EOF
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: "netshoot-${SUFFIX}"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: "netshoot-${SUFFIX}"
spec:
  replicas: 1
  selector:
    matchLabels:
      app: "netshoot-${SUFFIX}"
  template:
    metadata:
      labels:
        app: "netshoot-${SUFFIX}"
    spec:
      serviceAccountName: "netshoot-${SUFFIX}"
      containers:
      - name: "netshoot-${SUFFIX}"
        image: docker.io/nicolaka/netshoot:v0.12
        command: ["/bin/sh", "-c", "while true; do sleep 10; done"]
EOF
    sleep 2
    kubectl --context ${CURRENT_CONTEXT} --namespace "${NS}" rollout status "deploy/netshoot-${SUFFIX}"
  done

for VERSION in "v1" "v2"
do
  kubectl --context ${CURRENT_CONTEXT} --namespace "${SERVER_APP_NAMESPACE}" apply -f - << EOF
---
apiVersion: v1
kind: Service
metadata:
  name: "echo-server-${VERSION}"
  labels:
    app: "echo-server-${VERSION}"
    service: "echo-server-${VERSION}"
spec:
  ports:
  - port: 8080
    name: http
  - port: 9080
    name: http2-grpc
  selector:
    app: "echo-server-${VERSION}"
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: "echo-server-${VERSION}"
  labels:
    account: "echo-server-${VERSION}"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: "echo-server-${VERSION}"
  labels:
    app: "echo-server-${VERSION}"
    version: "${VERSION}"
spec:
  replicas: 1
  selector:
    matchLabels:
      app: "echo-server-${VERSION}"
      version: "${VERSION}"
  template:
    metadata:
      labels:
        app: "echo-server-${VERSION}"
        version: "${VERSION}"
    spec:
      serviceAccountName: "echo-server-${VERSION}"
      containers:
      - name: "echo-server-${VERSION}"
        image: ghcr.io/nmnellis/istio-echo:latest
        imagePullPolicy: IfNotPresent
        ports:
        - containerPort: 8080
        args:
          - --name
          - "echo-server-${VERSION}"
          - --port
          - "8080"
          - --grpc
          - "9080"
          - --version
          - "${VERSION}"
          - --cluster
          - "${CURRENT_CONTEXT}"
EOF

sleep 2
kubectl --context ${CURRENT_CONTEXT} --namespace "${SERVER_APP_NAMESPACE}" rollout status "deploy/echo-server-${VERSION}"
done

# kubectl --context ${CURRENT_CONTEXT} --namespace "${SERVER_APP_NAMESPACE}" apply -f https://raw.githubusercontent.com/istio/istio/master/samples/httpbin/httpbin.yaml
done

echo
echo "#############################################################################"
echo "---- Create Ingress Gateway in cluster 1 ----"
echo "#############################################################################"
echo
GATEWAY_NS=istio-gateways
kubectl --context k3d-workload-cluster1 create ns $GATEWAY_NS
kubectl --context k3d-workload-cluster1 apply -f - << EOF
apiVersion: v1
kind: Service
metadata:
  labels:
    app: istio-ingressgateway
    istio: ingressgateway
  name: istio-ingressgateway
  namespace: $GATEWAY_NS
spec:
  ports:
  - name: http2
    port: 8080
    protocol: TCP
    targetPort: 8080
  - name: https
    port: 8443
    protocol: TCP
    targetPort: 8443
  selector:
    app: istio-ingressgateway
    istio: ingressgateway
    revision: 1-23
  type: LoadBalancer
EOF

kubectl --context $MGMT_CONTEXT apply -f - << EOF
apiVersion: admin.gloo.solo.io/v2
kind: GatewayLifecycleManager
metadata:
  name: istio-ingressgateway-cluster1
  namespace: gloo-mesh
spec:
  installations:
      # The revision for this installation, such as 1-22
    - gatewayRevision: 1-23
      # List all workload clusters to install Istio into
      clusters:
      - name: k3d-workload-cluster1
        # If set to true, the spec for this revision is applied in the cluster
        activeGateway: true
      istioOperatorSpec:
        # No control plane components are installed
        profile: empty
        # Solo.io Istio distribution repository; required for Gloo Istio.
        # You get the repo key from your Solo Account Representative.
        hub: us-docker.pkg.dev/gloo-mesh/istio-workshops
        # The Solo.io Gloo Istio tag
        tag: 1.23.2-solo
        values:
          gateways:
            istio-ingressgateway:
              customService: true
        components:
          ingressGateways:
            - name: istio-ingressgateway
              namespace: $GATEWAY_NS
              enabled: true
              label:
                istio: ingressgateway
EOF

echo
echo "#############################################################################"
echo "---- Create East-West Gateway in cluster 2 ----"
echo "#############################################################################"
echo
kubectl apply --context $MGMT_CONTEXT -f- <<EOF
apiVersion: admin.gloo.solo.io/v2
kind: GatewayLifecycleManager
metadata:
  name: istio-eastwestgateway-cluster2
  namespace: gloo-mesh
spec:
  installations:
  - clusters:
    - activeGateway: true
      name: k3d-workload-cluster2
    gatewayRevision: 1-23
    istioOperatorSpec:
      # Solo.io Istio distribution repository; required for Gloo Istio.
      # You get the repo key from your Solo Account Representative.
      hub: us-docker.pkg.dev/gloo-mesh/istio-workshops
      # The Solo.io Gloo Istio tag
      tag: 1.23.2-solo
      components:
        ingressGateways:
        - enabled: true
          k8s:
            service:
              ports:
                - port: 15021
                  targetPort: 15021
                  name: status-port
                - port: 15443
                  targetPort: 15443
                  name: tls
              selector:
                istio: eastwestgateway
              type: LoadBalancer
          label:
            istio: eastwestgateway
            app: istio-eastwestgateway
          name: istio-eastwestgateway
          namespace: $GATEWAY_NS
      profile: empty
EOF

echo
echo "#############################################################################"
echo "---- istioctl proxy status check ----"
echo "#############################################################################"
echo
for ((i = 1; i <= NUMBER_OF_WORKLOAD_CLUSTERS; i++))
do
  CURRENT_CONTEXT="k3d-workload-cluster${i}"
  echo; echo "[DBEUG] Cluster: ${CURRENT_CONTEXT}"
  istioctl --context "${CURRENT_CONTEXT}" ps
done
