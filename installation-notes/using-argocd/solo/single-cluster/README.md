### Create kind cluster

```bash
export CLUSTER_NAME="gloo-mesh-single-cluster"
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

kind create cluster --name "${CLUSTER_NAME}" --config config.yaml
kubectl config rename-context "kind-${CLUSTER_NAME}" "${CLUSTER_NAME}"
rm -rf config.yaml
```

### Install ArgoCD

Also set login creds to id: admin, password: solo.io

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

### Create the ArgoCD applications

#### Gloo Mesh Enterprise
Put the license keys in place of the REDACTED keywords in `gloo-platform-helm-argo-app.yaml` and create the ArgoCD application:
```bash
kubectl apply -f 01-ops-config
```

#### Istiod and Istio Ingress Gateway install
```bash
kubectl apply -f 02-admin-config
```
