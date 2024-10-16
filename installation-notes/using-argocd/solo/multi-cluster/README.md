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

### pre-req license creation

We are manually creating the K8s Secret with the Gloo Mesh license keys here. This can be done in different ways. One of the alternate ways is to [use external-secrets operator to pre-create the license Secret](https://github.com/find-arka/gloo-mesh-notes/blob/main/custom-integration-notes/external-secrets/aws-secrets-manager/README.md).

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

### Create the ArgoCD applications

#### Gloo Mesh Enterprise

```bash
kubectl apply -f 01-ops-config/mgmt-cluster/gloo-platform-crds-argo-app.yaml --context "${MGMT}"
kubectl apply -f 01-ops-config/mgmt-cluster/gloo-platform-helm-argo-app.yaml --context "${MGMT}"
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
```bash
kubectl apply -f 02-admin-config
```
