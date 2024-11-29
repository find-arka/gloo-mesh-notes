- [Zero trust setup notes](#zero-trust-setup-notes)
  - [Environment setup with k3d and docker](#environment-setup-with-k3d-and-docker)
  - [Setup mTLS and Zero trust by default](#setup-mtls-and-zero-trust-by-default)
    - [mTLS](#mtls)
    - [Default deny](#default-deny)
    - [Test that nothing works at this moment](#test-that-nothing-works-at-this-moment)
  - [Setup Zero visibility for sidecars](#setup-zero-visibility-for-sidecars)
    - [Validate that sample app is not aware of other endpoints](#validate-that-sample-app-is-not-aware-of-other-endpoints)
  - [Selectively allow traffic from one in-mesh app to another in-mesh app](#selectively-allow-traffic-from-one-in-mesh-app-to-another-in-mesh-app)
    - [Set visibility](#set-visibility)
    - [Define explicit allow rule](#define-explicit-allow-rule)
    - [Test that only the allowed path is now working](#test-that-only-the-allowed-path-is-now-working)
  - [Setup domain based routing using the Istio ingress gateway](#setup-domain-based-routing-using-the-istio-ingress-gateway)
    - [Create gateways-workspace](#create-gateways-workspace)
    - [import from server-workspace](#import-from-server-workspace)
    - [export to gateways-workspace](#export-to-gateways-workspace)
    - [Add explicit allow rule for ingress to server-v1 traffic](#add-explicit-allow-rule-for-ingress-to-server-v1-traffic)
    - [Routing config - create VirtualGateway](#routing-config---create-virtualgateway)
    - [Routing config - create RouteTable](#routing-config---create-routetable)
    - [test using grpcurl](#test-using-grpcurl)
      - [port-forward the Ingress gateway](#port-forward-the-ingress-gateway)
      - [grpcurl through the localhost with explicit authority for hostname mapping](#grpcurl-through-the-localhost-with-explicit-authority-for-hostname-mapping)
      - [Current state](#current-state)

# Zero trust setup notes

## Environment setup with k3d and docker

```bash
chmod +x setup-multicluster-gme-k3d-1-23.sh
./setup-multicluster-gme-k3d-1-23.sh
```

The script takes about 5 minutes and does the following:

- Create a docker network, creates 3 k3d clusters
- Installs Gloo Mesh mgmt server, Gloo Mesh agents
- Installs Istio ingress gateway in cluster 1 , egress gateway in cluster 2
- Installs some in-mesh apps (sidecar injected) and one outside mesh app (in default NS)-

![initial-setup](./assets/apps-initial-state.png)

## Setup mTLS and Zero trust by default

### mTLS

```bash
#PeerAuthentication:  To setup STRICT mTLS everywhere posture
for ((i = 1; i <= 2; i++))
do
  CURRENT_CONTEXT="k3d-workload-cluster${i}"
  kubectl apply --context ${CURRENT_CONTEXT} -f - <<EOF
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: default-strict-mtls
  namespace: istio-system
spec:
  mtls:
    mode: STRICT
EOF
done
```

### Default deny

```bash
#AuthorizationPolicy: To setup deny all traffic by default - zero trust security posture
for ((i = 1; i <= 2; i++))
do
  CURRENT_CONTEXT="k3d-workload-cluster${i}"
  kubectl apply --context ${CURRENT_CONTEXT} -f - <<EOF
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
 name: allow-nothing
 namespace: istio-system
spec:
  {}
EOF
done
```

### Test that nothing works at this moment

Expectation: #1, #2, #3 should all fail due to default deny posture

```bash
#1 Test access from app outside mesh (i.e. no sidecar) to app inside the mesh (has a sidecar)
kubectl --context k3d-workload-cluster1 -n default \
  exec -it deploy/netshoot-outside-mesh -c netshoot-outside-mesh \
  -- curl "http://echo-server-v1.server-app-namespace.svc.cluster.local:8080"

#2 Test access from app inside mesh but from different Namespace
kubectl --context k3d-workload-cluster1 -n client-app-namespace \
  exec -it deploy/netshoot-client-app-namespace -c netshoot-client-app-namespace \
  -- curl "http://echo-server-v1.server-app-namespace.svc.cluster.local:8080"

#3 Test access from app inside mesh and from the same Namespace
kubectl --context k3d-workload-cluster1 -n server-app-namespace \
  exec -it deploy/netshoot-server-app-namespace -c netshoot-server-app-namespace \
  -- curl "http://echo-server-v1.server-app-namespace.svc.cluster.local:8080"
```

![deny](./assets/deny-all.png)

## Setup Zero visibility for sidecars

```bash
# Trim proxy visibility
#WS, WSS
REMOTE_CONTEXT1="k3d-workload-cluster1"
REMOTE_CONTEXT2="k3d-workload-cluster2"
MGMT_CONTEXT=k3d-gloo-mgmt-cluster

# Create Config NS in mgmt cluster
kubectl --context ${MGMT_CONTEXT} create namespace "client-app-namespace-config"
kubectl --context ${MGMT_CONTEXT} create namespace "server-app-namespace-config"

# WS and Settings
kubectl apply --context ${MGMT_CONTEXT} -f- <<EOF
---
apiVersion: admin.gloo.solo.io/v2
kind: Workspace
metadata:
  name: client-app-workspace
  namespace: gloo-mesh
spec:
  workloadClusters:
  - name: ${MGMT_CONTEXT}
    namespaces:
    - name: "client-app-namespace-config"
# ---- "configEnabled: true" indicates we will save Gloo Mesh config in this namespace ----
    configEnabled: true
  - name: ${REMOTE_CONTEXT1}
    namespaces:
    - name: client-app-namespace
# ---- "configEnabled: false" The actual workloads run on this namespace, gloo mesh config doesn't live here ----
    configEnabled: false
  - name: ${REMOTE_CONTEXT2}
    namespaces:
    - name: client-app-namespace
    configEnabled: false
---
apiVersion: admin.gloo.solo.io/v2
kind: WorkspaceSettings
metadata:
  name: client-app-workspace
  namespace: "client-app-namespace-config"
spec:
# ---- importFrom "server-app-workspace" so that the Services can be accessed ----
  importFrom:
  - workspaces:
    - name: server-app-workspace
  options:
# ---- Set zero visibility for the sidecars ----
    trimAllProxyConfig: true
# ---- Setting serviceIsolation.enabled to false since we are uisng allow-nothing AuthorizationPolicy to setup default deny posture ----
    serviceIsolation:
      enabled: false
---
apiVersion: admin.gloo.solo.io/v2
kind: Workspace
metadata:
  name: server-app-workspace
  namespace: gloo-mesh
spec:
  workloadClusters:
  - name: ${MGMT_CONTEXT}
    namespaces:
    - name: server-app-namespace-config
    configEnabled: true
  - name: ${REMOTE_CONTEXT1}
    namespaces:
    - name: server-app-namespace
    configEnabled: false
  - name: ${REMOTE_CONTEXT2}
    namespaces:
    - name: server-app-namespace
    configEnabled: false
---
apiVersion: admin.gloo.solo.io/v2
kind: WorkspaceSettings
metadata:
  name: server-app-workspace
  namespace: server-app-namespace-config
spec:
# ---- exportTo "client-app-workspace" so that the Services can be accessed from "client-app-workspace" ----
  exportTo:
  - workspaces:
    - name: client-app-workspace
  options:
    trimAllProxyConfig: true
    serviceIsolation:
      enabled: false
EOF
```

### Validate that sample app is not aware of other endpoints

```bash
istioctl proxy-config endpoint \
  --context k3d-workload-cluster1 -n client-app-namespace \
  deploy/netshoot-client-app-namespace
```

Output should only show these-

```bash
ENDPOINT                                                STATUS      OUTLIER CHECK     CLUSTER
127.0.0.1:15000                                         HEALTHY     OK                prometheus_stats
127.0.0.1:15020                                         HEALTHY     OK                agent
unix://./etc/istio/proxy/XDS                            HEALTHY     OK                xds-grpc
unix://./var/run/secrets/workload-spiffe-uds/socket     HEALTHY     OK                sds-grpc
```

> *At this point we have default deny posture everywhere, with minimal visibility for sidecars and with STRICT mTLS requirement everywhere*

## Selectively allow traffic from one in-mesh app to another in-mesh app

### Set visibility

```bash
kubectl apply --context k3d-gloo-mgmt-cluster -f- <<EOF
apiVersion: resilience.policy.gloo.solo.io/v2
kind: TrimProxyConfigPolicy
metadata:
  name: trim-netshoots-visibility-cross-namespace
  namespace: client-app-namespace-config
spec:
  applyToWorkloads:
# ---- select the source workload on which this policy is applied  ----
  - selector:
      name: netshoot-client-app-namespace
      namespace: client-app-namespace
      workspace: client-app-workspace
  config:
    includedDestinations:
# ---- define the destination that should be visible from netshoot----
    - selector:
        name: echo-server-v1
        namespace: server-app-namespace
        workspace: server-app-workspace
EOF
```

> `istioctl proxy-config endpoint --context k3d-workload-cluster1 -n client-app-namespace deploy/netshoot-client-app-namespace` should now show the `echo-server-v1` endpoints

### Define explicit allow rule

```bash
kubectl apply --context k3d-gloo-mgmt-cluster -f- <<EOF
apiVersion: security.policy.gloo.solo.io/v2
kind: AccessPolicy
metadata:
  name: echo-server-v1-app-access
  namespace: server-app-namespace-config
spec:
  applyToWorkloads:
# ---- Define the destination workload which will be allowed to access ----
  - selector:
      labels:
        app: echo-server-v1
      namespace: server-app-namespace
      workspace: server-app-workspace
  config:
# ---- Important to set tlsMode: STRICT here as well ----
    authn:
      tlsMode: STRICT
    authz:
# ---- Define the source workload which can access the server ----
      allowedClients:
      - serviceAccountSelector:
          namespace: client-app-namespace
          name: netshoot-client-app-namespace
EOF
```

### Test that only the allowed path is now working

![selective-success](./assets/selective-success.png)

Expectation: Only #2 shall succeed and rest all shall fail

> Note: It takes a little bit of time for the config to be applied. So in case you don't get success on the first sample curl, try a couple more time and then the behavior becomes consistent once the policy changes are updated as envoy config.

```bash
#1 Test access from app outside mesh (i.e. no sidecar) to app inside the mesh (has a sidecar)
kubectl --context k3d-workload-cluster1 -n default \
  exec -it deploy/netshoot-outside-mesh -c netshoot-outside-mesh \
  -- curl "http://echo-server-v1.server-app-namespace.svc.cluster.local:8080"
```

```bash
#2 Test access from app inside mesh but from different Namespace
kubectl --context k3d-workload-cluster1 -n client-app-namespace \
  exec -it deploy/netshoot-client-app-namespace -c netshoot-client-app-namespace \
  -- curl "http://echo-server-v1.server-app-namespace.svc.cluster.local:8080"
```

```bash
#3 Test access from app inside mesh and from the same Namespace
kubectl --context k3d-workload-cluster1 -n server-app-namespace \
  exec -it deploy/netshoot-server-app-namespace -c netshoot-server-app-namespace \
  -- curl "http://echo-server-v1.server-app-namespace.svc.cluster.local:8080"
```

## Setup domain based routing using the Istio ingress gateway

### Create gateways-workspace

```bash
MGMT_CONTEXT=k3d-gloo-mgmt-cluster
REMOTE_CONTEXT1="k3d-workload-cluster1"
REMOTE_CONTEXT2="k3d-workload-cluster2"
# config NS creation
kubectl --context ${MGMT_CONTEXT} create namespace "gateways-config";
# Workspace creation
kubectl apply --context ${MGMT_CONTEXT} -f- <<EOF
apiVersion: admin.gloo.solo.io/v2
kind: Workspace
metadata:
  name: gateways-workspace
  namespace: gloo-mesh
spec:
  workloadClusters:
  - name: ${MGMT_CONTEXT}
    namespaces:
    - name: gateways-config
    configEnabled: true
  - name: ${REMOTE_CONTEXT1}
    namespaces:
    - name: 'istio-gateways'
    configEnabled: false
  - name: ${REMOTE_CONTEXT2}
    namespaces:
    - name: 'istio-gateways'
    configEnabled: false
EOF
```

### import from server-workspace

```bash
kubectl apply --context ${MGMT_CONTEXT} -f- <<EOF
---
apiVersion: admin.gloo.solo.io/v2
kind: WorkspaceSettings
metadata:
  name: gateways-workspace
  namespace: gateways-config
spec:
  importFrom:
  - workspaces:
    - name: "server-app-workspace"
  options:
# trimAllProxyConfig not set to true since Istio "Sidecar" custom resource is not applicable to gateways
# https://istio.io/latest/docs/reference/config/networking/sidecar/#:~:text=A%20Sidecar%20is%20not%20applicable%20to%20gateways
    serviceIsolation:
      enabled: false
EOF
```

### export to gateways-workspace

```bash
kubectl apply --context ${MGMT_CONTEXT} -f- <<EOF
apiVersion: admin.gloo.solo.io/v2
kind: WorkspaceSettings
metadata:
  name: server-app-workspace
  namespace: server-app-namespace-config
spec:
  exportTo:
  - workspaces:
    - name: client-app-workspace
# ---- exportTo gateways-workspace" so that the Services can be accessed from "client-app-workspace" ----
    - name: gateways-workspace
  options:
    trimAllProxyConfig: true
    serviceIsolation:
      enabled: false
EOF
```

### Add explicit allow rule for ingress to server-v1 traffic

```bash
kubectl apply --context k3d-gloo-mgmt-cluster -f- <<EOF
apiVersion: security.policy.gloo.solo.io/v2
kind: AccessPolicy
metadata:
  name: echo-server-v1-app-access
  namespace: server-app-namespace-config
spec:
  applyToWorkloads:
  - selector:
      labels:
        app: echo-server-v1
      namespace: server-app-namespace
      workspace: server-app-workspace
  config:
    authn:
      tlsMode: STRICT
    authz:
      allowedClients:
      - serviceAccountSelector:
          namespace: client-app-namespace
          name: netshoot-client-app-namespace
# ---- Additional source workload which can access the echo-server-v1 ----
      - serviceAccountSelector:
          namespace: istio-gateways
          name: istio-ingressgateway-1-23-service-account
EOF
```

### Routing config - create VirtualGateway

```bash
kubectl --context ${MGMT_CONTEXT} apply -f - <<EOF
apiVersion: networking.gloo.solo.io/v2
kind: VirtualGateway
metadata:
  name: north-south-gw-common
  namespace: gateways-config
spec:
  workloads:
    - selector:
        labels:
          istio: ingressgateway
        cluster: k3d-workload-cluster1
  listeners: 
    - http: {}
      port:
        number: 8080
EOF
```

### Routing config - create RouteTable

Domain based routing: `echo-server-v1.consultsolo.net`

```bash
kubectl --context ${MGMT_CONTEXT} apply -f - <<EOF
apiVersion: networking.gloo.solo.io/v2
kind: RouteTable
metadata:
  name: ingress-to-echo-server-v1-grpc
  namespace: server-app-namespace-config
spec:
  hosts:
    - 'echo-server-v1.consultsolo.net'
  virtualGateways:
    - name: north-south-gw-common
      namespace: gateways-config
      cluster: ${MGMT_CONTEXT}
  workloadSelectors: []
  http:
    - name: ingress-to-echo-server-v1-route
      matchers:
      - uri:
          prefix: /
      forwardTo:
        destinations:
          - kind: SERVICE
            ref:
              name: echo-server-v1
              namespace: server-app-namespace
            port:
              # --- gRPC port for the application ---
              number: 9080
EOF
```

### test using grpcurl

#### port-forward the Ingress gateway

```bash
kubectl --context k3d-workload-cluster1 -n istio-gateways port-forward deploy/istio-ingressgateway-1-23 8080
```

#### grpcurl through the localhost with explicit authority for hostname mapping

```bash
grpcurl -authority echo-server-v1.consultsolo.net -plaintext localhost:8080 proto.EchoTestService/Echo | jq -r '.message'
```

#### Current state

Error message:

```bash
Error invoking method "proto.EchoTestService/Echo": rpc error: code = PermissionDenied desc = failed to query for service descriptor "proto.EchoTestService": RBAC: access denied
```

Access log from ingress gateway

```json
{
  "authority": "echo-server-v1.consultsolo.net",
  "bytes_received": 0,
  "bytes_sent": 0,
  "connection_termination_details": null,
  "downstream_local_address": "127.0.0.1:8080",
  "downstream_remote_address": "127.0.0.1:50570",
  "duration": 0,
  "method": "POST",
  "path": "/grpc.reflection.v1.ServerReflection/ServerReflectionInfo",
  "protocol": "HTTP/2",
  "request_id": "66f61b94-e66c-415f-aafe-55fb9a2aaa1c",
  "requested_server_name": null,
  "response_code": 200,
  "response_code_details": "rbac_access_denied_matched_policy[none]",
  "response_flags": "-",
  "route_name": "insecure-ingress-to-echo-server-269c4eb90b79a85fa2119a873455d89",
  "start_time": "2024-11-29T22:47:16.307Z",
  "upstream_cluster": "outbound|9080||echo-server-v1.server-app-namespace.svc.cluster.local;",
  "upstream_host": null,
  "upstream_local_address": null,
  "upstream_service_time": null,
  "upstream_transport_failure_reason": null,
  "user_agent": "grpcurl/1.9.1 grpc-go/1.61.0",
  "x_forwarded_for": "10.42.0.19"
}
{
  "authority": "echo-server-v1.consultsolo.net",
  "bytes_received": 0,
  "bytes_sent": 0,
  "connection_termination_details": null,
  "downstream_local_address": "127.0.0.1:8080",
  "downstream_remote_address": "127.0.0.1:50570",
  "duration": 0,
  "method": "POST",
  "path": "/grpc.reflection.v1.ServerReflection/ServerReflectionInfo",
  "protocol": "HTTP/2",
  "request_id": "42d13121-6cc0-44bf-9e05-ef0d9ffbeb12",
  "requested_server_name": null,
  "response_code": 200,
  "response_code_details": "rbac_access_denied_matched_policy[none]",
  "response_flags": "-",
  "route_name": "insecure-ingress-to-echo-server-269c4eb90b79a85fa2119a873455d89",
  "start_time": "2024-11-29T22:47:16.308Z",
  "upstream_cluster": "outbound|9080||echo-server-v1.server-app-namespace.svc.cluster.local;",
  "upstream_host": null,
  "upstream_local_address": null,
  "upstream_service_time": null,
  "upstream_transport_failure_reason": null,
  "user_agent": "grpcurl/1.9.1 grpc-go/1.61.0",
  "x_forwarded_for": "10.42.0.19"
}
{
  "authority": "echo-server-v1.consultsolo.net",
  "bytes_received": 0,
  "bytes_sent": 0,
  "connection_termination_details": null,
  "downstream_local_address": "127.0.0.1:8080",
  "downstream_remote_address": "127.0.0.1:50570",
  "duration": 0,
  "method": "POST",
  "path": "/grpc.reflection.v1.ServerReflection/ServerReflectionInfo",
  "protocol": "HTTP/2",
  "request_id": "71d0353f-f159-406f-b3f3-eaa561c987bd",
  "requested_server_name": null,
  "response_code": 200,
  "response_code_details": "rbac_access_denied_matched_policy[none]",
  "response_flags": "-",
  "route_name": "insecure-ingress-to-echo-server-269c4eb90b79a85fa2119a873455d89",
  "start_time": "2024-11-29T22:47:16.308Z",
  "upstream_cluster": "outbound|9080||echo-server-v1.server-app-namespace.svc.cluster.local;",
  "upstream_host": null,
  "upstream_local_address": null,
  "upstream_service_time": null,
  "upstream_transport_failure_reason": null,
  "user_agent": "grpcurl/1.9.1 grpc-go/1.61.0",
  "x_forwarded_for": "10.42.0.19"
}
```

GME Gateway view

![gme-gateway](./assets/gme-gateway.png)