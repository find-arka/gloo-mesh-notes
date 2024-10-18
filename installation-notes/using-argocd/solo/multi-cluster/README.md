# Gloo Platform Configuration Management and Install using ArgoCD in Multiple Clusters

## Pre-reqs

You will need to have at least two clusters, one for the management plane server and one for the workloads. The steps for the workload clusters can be replicated for more workload clusters

### Create kind clusters

- Management plane cluster:

```bash
export MGMT="gloo-mesh-management-cluster"
cat <<EOF > config.yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking:
  disableDefaultCNI: false
# 1 control plane node and 3 workers
nodes:
# the control plane node config
- role: control-plane
  labels:
    topology.kubernetes.io/region: us-west1
    topology.kubernetes.io/zone: us-west1-a
# the three workers
- role: worker
  labels:
    topology.kubernetes.io/region: us-west1
    topology.kubernetes.io/zone: us-west1-a
- role: worker
  labels:
    topology.kubernetes.io/region: us-west2
    topology.kubernetes.io/zone: us-west2-b
- role: worker
  labels:
    topology.kubernetes.io/region: us-west3
    topology.kubernetes.io/zone: us-west3-c
EOF

kind create cluster --name "${MGMT}" --config config.yaml
kubectl config rename-context "kind-${MGMT}" "${MGMT}"
rm -rf config.yaml
```

- Workload cluster:

```bash
export CLUSTER_1="gloo-mesh-workload-cluster"
cat <<EOF > config.yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking:
  disableDefaultCNI: false
# 1 control plane node and 3 workers
nodes:
# the control plane node config
- role: control-plane
  labels:
    topology.kubernetes.io/region: us-west1
    topology.kubernetes.io/zone: us-west1-a
# the three workers
- role: worker
  labels:
    topology.kubernetes.io/region: us-west1
    topology.kubernetes.io/zone: us-west1-a
- role: worker
  labels:
    topology.kubernetes.io/region: us-west2
    topology.kubernetes.io/zone: us-west2-b
- role: worker
  labels:
    topology.kubernetes.io/region: us-west3
    topology.kubernetes.io/zone: us-west3-c
EOF

kind create cluster --name "${CLUSTER_1}" --config config.yaml
kubectl config rename-context "kind-${CLUSTER_1}" "${CLUSTER_1}"
rm -rf config.yaml
```

### Install ArgoCD

- Also set login creds to id: admin, password: solo.io

- Replace ${CLUSTER_NAME} with MGMT and CLUSTER_1 and perform the steps on each cluster:

```bash
kubectl create namespace argocd --context "${CLUSTER_NAME}"
until kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/v2.9.5/manifests/install.yaml --context "${CLUSTER_NAME}" > /dev/null 2>&1
do
	sleep 2
done
kubectl --context "${CLUSTER_NAME}" -n argocd rollout status deploy/argocd-applicationset-controller
kubectl --context "${CLUSTER_NAME}" -n argocd rollout status deploy/argocd-dex-server
kubectl --context "${CLUSTER_NAME}" -n argocd rollout status deploy/argocd-notifications-controller
kubectl --context "${CLUSTER_NAME}" -n argocd rollout status deploy/argocd-redis
kubectl --context "${CLUSTER_NAME}" -n argocd rollout status deploy/argocd-repo-server
kubectl --context "${CLUSTER_NAME}" -n argocd rollout status deploy/argocd-server
echo "sleeping for 10 sec before updating admin password"
sleep 10
# Set creds to admin, solo.io
kubectl --context "${CLUSTER_NAME}" -n argocd patch secret argocd-secret -p '{"stringData": {
"admin.password": "$2a$10$79yaoOg9dL5MO8pn8hGqtO4xQDejSEVNWAGQR268JHLdrCw6UCYmy",
"admin.passwordMtime": "'$(date +%FT%T%Z)'"
}}'
```

## mTLS agent-server relay setup

### pre-req license creation and secrets for relay

- We are manually creating the K8s Secret with the Gloo Mesh license keys here. This can be done in different ways. One of the alternate ways is to [use external-secrets operator to pre-create the license Secret](https://github.com/find-arka/gloo-mesh-notes/blob/main/custom-integration-notes/external-secrets/aws-secrets-manager/README.md).

```bash
kubectl create namespace gloo-mesh
```

```bash
kubectl apply -f -<< EOF
apiVersion: v1
kind: Secret
type: Opaque
metadata:
  name: gloo-mesh-enterprise-license-keys
  namespace: gloo-mesh
stringData:
  gloo-mesh-license-key: "${GLOO_MESH_LICENSE_KEY}"
  gloo-gateway-license-key: "${GLOO_GATEWAY_LICENSE_KEY}"
EOF
```

- Create relay secrets for mTLS in between agents and MP server. To create our root-ca cert we are going to use the tool/cert from istio repository:

```bash
git clone https://github.com/istio/istio.git --depth 1
pushd istio/tools/certs
```

IMPORTANT: We are using istio tools and selfsigned certs just for the purpose to enable end to end encription between out components, for production usage proper certificated that depict the desired trust domain for the clusters should be used.

- Create the root cert:

```bash
# ROOTCA_ORG is a variable than can be changed use whatever you want
make -f Makefile.selfsigned.mk ROOTCA_ORG=my-org root-ca
```

- Create the relay intermediate CA for gloo:

```bash
# Here you need to use a different INTEMEDIATE_SAN_DNS from the variable in the makefile
make -f Makefile.selfsigned.mk INTERMEDIATE_ORG=solo INTERMEDIATE_SAN_DNS=gloo-mesh-mgmt-server.gloo-mesh gloo-relay-cacerts
```

Note that for the intermediate SAN, we use `gloo-mesh-mgmt-server.gloo-mesh` or can be a wild card `*.gloo-mesh` which is the mgmt server expects for connecting using mTLS otherwise the connection will be rejected with the following error:

```json
{"level":"info","ts":"2024-04-09T18:17:09.171Z","caller":"grpclog/component.go:36","msg":"[core][Channel #5 SubChannel #6] Subchannel Connectivity change to IDLE, last error: connection error: desc = \"transport: authentication handshake failed: tls: failed to verify certificate: x509: certificate is valid for istiod.istio-system.svc, not gloo-mesh-mgmt-server.gloo-mesh\"","system":"grpc","grpc_log":true}
```

- Create a leaf relay-server-tls cert with the intermediate CA certificate
Unfortunately, the make file cannot sign a certificate with our intermediate certificate, so we need to do it manually.

> [!NOTE] Due to the server limitations, the mgmt plane cannot create the `relay-server-tls-secret` as opposed for the client which can be handled and managed by Gloo.

Run the following go script to generate a certificate with out signing cacerts.

```bash
go run ../../security/tools/generate_cert/main.go --host="*.gloo-mesh" --signer-cert=gloo-relay/ca-cert.pem --signer-priv=gloo-relay/ca-key.pem --server=true --san="*.gloo-mesh" --mode=signer --out-cert="relay-server-cert.pem" --out-priv="relay-server-key.pem"
```

```bash
go run ../../security/tools/generate_cert/main.go --host="gloo-telemetry-gateway.gloo-mesh" --signer-cert=gloo-relay/ca-cert.pem --signer-priv=gloo-relay/ca-key.pem --server=true --san="gloo-telemetry-gateway.gloo-mesh" --mode=signer --out-cert="gloo-telemetry-gateway-cert.pem" --out-priv="gloo-telemetry-gateway-key.pem"
```

### Create the certificates in the mgmt cluster and workload clusters

Now we are going to create the secrets beforehand and install the gloo mgmt plane.

IMPORTANT: These secrets could be orchestrated to be created using any prefered external secret manager, but they will have to exist before the releases are installed.

```sh
export MGMT=mgmt
export CLUSTER1=cluster1
```

```bash
kubectl create namespace gloo-mesh --context ${MGMT}

kubectl create secret generic relay-root-tls-secret \
  --from-file=tls.key=gloo-relay/ca-key.pem \
  --from-file=tls.crt=gloo-relay/ca-cert.pem \
  --from-file=ca.crt=gloo-relay/cert-chain.pem \
  --context ${MGMT} \
  --namespace gloo-mesh

kubectl create secret generic relay-tls-signing-secret \
  --from-file=tls.key=gloo-relay/ca-key.pem \
  --from-file=tls.crt=gloo-relay/ca-cert.pem \
  --from-file=ca.crt=gloo-relay/cert-chain.pem \
  --context ${MGMT} \
  --namespace gloo-mesh

kubectl create secret generic relay-server-tls-secret \
  --from-file=tls.key=relay-server-key.pem \
  --from-file=tls.crt=relay-server-cert.pem \
  --from-file=ca.crt=gloo-relay/cert-chain.pem \
  --context ${MGMT} \
  --namespace gloo-mesh

kubectl create secret generic gloo-telemetry-gateway-tls-secret \
  --from-file=tls.key=gloo-telemetry-gateway-key.pem \
  --from-file=tls.crt=gloo-telemetry-gateway-cert.pem \
  --from-file=ca.crt=gloo-relay/cert-chain.pem \
  --context ${MGMT} \
  --namespace gloo-mesh
```

Let's do the same in the workload cluster:

```bash
kubectl create namespace gloo-mesh --context ${CLUSTER1}

kubectl create secret generic relay-root-tls-secret \
  --from-file=tls.key=gloo-relay/ca-key.pem \
  --from-file=tls.crt=gloo-relay/ca-cert.pem \
  --from-file=ca.crt=gloo-relay/cert-chain.pem \
  --context ${CLUSTER1} \
  --namespace gloo-mesh
  popd
```

### Create the ArgoCD applications

#### Gloo Mesh Enterprise

- Install the ArgoCD Gloo Platform CRD App and Helm app:

```bash
kubectl apply -f 01-ops-config/mgmt-cluster/gloo-platform-crds-argo-app.yaml --context "${MGMT}"
kubectl apply -f 01-ops-config/mgmt-cluster/gloo-platform-helm-argo-app.yaml --context "${MGMT}"
```

- Install the ArgoCD Gloo CRDs app in the workload cluster:

```bash
kubectl apply -f 01-ops-config/mgmt-cluster/gloo-platform-crds-argo-app.yaml --context "${CLUSTER_1}"
```

- Get the telemetry gateway and the management server addresses:

```sh
# wait for the load balancer to be provisioned
until kubectl get service/gloo-mesh-mgmt-server --output=jsonpath='{.status.loadBalancer}' --context ${MGMT} -n gloo-mesh | grep "ingress"; do : ; done
until kubectl get service/gloo-telemetry-gateway --output=jsonpath='{.status.loadBalancer}' --context ${MGMT} -n gloo-mesh | grep "ingress"; do : ; done
export GLOO_PLATFORM_SERVER_DOMAIN=$(kubectl get svc gloo-mesh-mgmt-server --context ${MGMT} -n gloo-mesh -o jsonpath='{.status.loadBalancer.ingress[0].*}')
export GLOO_PLATFORM_SERVER_ADDRESS=${GLOO_PLATFORM_SERVER_DOMAIN}:$(kubectl get svc gloo-mesh-mgmt-server --context ${MGMT} -n gloo-mesh -o jsonpath='{.spec.ports[?(@.name=="grpc")].port}')
export GLOO_TELEMETRY_GATEWAY=$(kubectl get svc gloo-telemetry-gateway --context ${MGMT} -n gloo-mesh -o jsonpath='{.status.loadBalancer.ingress[0].*}'):$(kubectl get svc gloo-telemetry-gateway --context ${MGMT} -n gloo-mesh -o jsonpath='{.spec.ports[?(@.port==4317)].port}')

echo "Mgmt Plane Address: $GLOO_PLATFORM_SERVER_ADDRESS"
echo "Metrics Gateway Address: $GLOO_TELEMETRY_GATEWAY"
```

These are going to be used on the agent config:

```sh
envsubst < 01-ops-config/workload-cluster/gloo-agent-helm-argo-app.yaml | k --context "${CLUSTER_1}" apply -f -
```

#### Istiod and Istio Ingress Gateway install

- Create the root trust policy on the MP to generate trust in between cluster data planes

IMPORTANT: This is assuming we accept the out of the box trust domain for the data plane.

```sh
kubectl apply --context ${MGMT} -f- << EOF
apiVersion: admin.gloo.solo.io/v2
kind: RootTrustPolicy
metadata:
  name: root-trust-policy
  namespace: gloo-mesh
spec:
  config:
    autoRestartPods: true
    intermediateCertOptions:
      secretRotationGracePeriodRatio: 0.1
      ttlDays: 1
    mgmtServerCa:
      generated:
        ttlDays: 730
EOF
```

- Create IstioLifeCycle Manager instance for your workload clusters:

```bash
kubectl apply -f 02-admin-config/gloo-platform-istiolifecyclemanager-argo-app.yaml --context ${MGMT}
```

- Create the GatewayLifeCycle Manager instance for your workload cluster:

```bash
kubectl apply -f 02-admin-config/gloo-platform-gatewaylifecyclemanager-argo-app.yaml --context ${MGMT}
```

## Simple TLS agent-server relay setup

This setup secures the relay connection between the Gloo management server and agents by using simple TLS. In a simple TLS setup only the Gloo management server is configured with a server TLS certificate that is used to prove the server’s identity. The identity of the Gloo agent is not verified. To establish initial trust, relay tokens are used.

### Create the token secrets

```bash
kubectl --context "${MGMT}" apply -f -<< EOF
apiVersion: v1
kind: Secret
type: Opaque
metadata:
  name: relay-identity-token-secret
  namespace: gloo-mesh
stringData:
  token: "my-secret-token"
EOF
```

```bash
kubectl --context "${CLUSTER_1}" apply -f -<< EOF
apiVersion: v1
kind: Secret
type: Opaque
metadata:
  name: relay-identity-token-secret
  namespace: gloo-mesh
stringData:
  token: "my-secret-token"
EOF
```

### Create the ArgoCD applications

#### Gloo Mesh Enterprise

- Install the ArgoCD Gloo Platform CRD App and Helm app:

```bash
kubectl apply -f simple-tls-agent-server/01-ops-config/common/gloo-platform-crds-argo-app.yaml --context "${MGMT}"
kubectl apply -f simple-tls-agent-server/01-ops-config/mgmt-cluster/gloo-platform-helm-argo-app.yaml --context "${MGMT}"
```

`meshctl check --kubecontext "${MGMT}"` output:

```bash
{"level":"info","ts":"2024-10-18T14:09:41.026-0400","caller":"client/client.go:283","msg":"VALID LICENSE: gloo-mesh Enterprise, issued at 2024-02-29 17:04:52 -0500 EST, expires at 2026-07-30 18:04:52 -0400 EDT"}
{"level":"info","ts":"2024-10-18T14:09:41.027-0400","caller":"client/client.go:283","msg":"VALID LICENSE: gloo-gateway Enterprise, issued at 2024-02-29 17:06:21 -0500 EST, expires at 2026-07-30 18:06:21 -0400 EDT"}

🟢 License status

 INFO  gloo-mesh enterprise license expiration is 30 Jul 26 18:04 EDT
 INFO  gloo-gateway enterprise license expiration is 30 Jul 26 18:06 EDT
 INFO  No GraphQL license module found for any product

🟢 CRD version check


🟢 Gloo Platform deployment status

Namespace | Name                           | Ready | Status
gloo-mesh | gloo-mesh-mgmt-server          | 1/1   | Healthy
gloo-mesh | gloo-mesh-redis                | 1/1   | Healthy
gloo-mesh | gloo-mesh-ui                   | 1/1   | Healthy
gloo-mesh | gloo-telemetry-gateway         | 1/1   | Healthy
gloo-mesh | prometheus-server              | 1/1   | Healthy
gloo-mesh | gloo-telemetry-collector-agent | 2/2   | Healthy

🟡 Mgmt server connectivity to workload agents

 INFO      * No registered clusters detected. To register a remote cluster that has a deployed Gloo Mesh agent, add a KubernetesCluster CR.
 INFO        For more info, see: https://docs.solo.io/gloo-mesh-enterprise/main/setup/install/enterprise_installation/#helm-register

Connected Pod | Clusters
```

#### Gloo Mesh workload cluster registration, installation

- Create the `KubernetesCluster` objects using the gloo-platform-kubernetes-clusters-argo-app.yaml

```bash
kubectl apply -f simple-tls-agent-server/01-ops-config/mgmt-cluster/gloo-platform-kubernetes-clusters-argo-app.yaml --context "${MGMT}"
```

- Install the ArgoCD Gloo CRDs app in the workload cluster:

```bash
kubectl apply -f simple-tls-agent-server/01-ops-config/common/gloo-platform-crds-argo-app.yaml --context "${CLUSTER_1}"
```

- Get the telemetry gateway and the management server addresses:

```sh
# wait for the load balancer to be provisioned
until kubectl get service/gloo-mesh-mgmt-server --output=jsonpath='{.status.loadBalancer}' --context ${MGMT} -n gloo-mesh | grep "ingress"; do : ; done
until kubectl get service/gloo-telemetry-gateway --output=jsonpath='{.status.loadBalancer}' --context ${MGMT} -n gloo-mesh | grep "ingress"; do : ; done
export GLOO_PLATFORM_SERVER_DOMAIN=$(kubectl get svc gloo-mesh-mgmt-server --context ${MGMT} -n gloo-mesh -o jsonpath='{.status.loadBalancer.ingress[0].*}')
export GLOO_PLATFORM_SERVER_ADDRESS=${GLOO_PLATFORM_SERVER_DOMAIN}:$(kubectl get svc gloo-mesh-mgmt-server --context ${MGMT} -n gloo-mesh -o jsonpath='{.spec.ports[?(@.name=="grpc")].port}')
export GLOO_TELEMETRY_GATEWAY=$(kubectl get svc gloo-telemetry-gateway --context ${MGMT} -n gloo-mesh -o jsonpath='{.status.loadBalancer.ingress[0].*}'):$(kubectl get svc gloo-telemetry-gateway --context ${MGMT} -n gloo-mesh -o jsonpath='{.spec.ports[?(@.name=="otlp")].port}')

echo "Mgmt Plane Address: $GLOO_PLATFORM_SERVER_ADDRESS"
echo "Metrics Gateway Address: $GLOO_TELEMETRY_GATEWAY"
```

These are going to be used on the agent config:

```sh
envsubst < simple-tls-agent-server/01-ops-config/workload-cluster/gloo-agent-helm-argo-app.yaml | kubectl --context "${CLUSTER_1}" apply -f -
```
