<!-- TOC start -->

- [mTLS relay setup with bring your own CA](#mtls-relay-setup-with-bring-your-own-ca)
  - [Cluster setup](#cluster-setup)
    - [Setup env variables](#setup-env-variables)
    - [Create clusters](#create-clusters)
  - [Install cert manager](#install-cert-manager)
  - [Create Root CA for Gloo Mesh in AWS Private CA](#create-root-ca-for-gloo-mesh-in-aws-private-ca)
  - [Setup IAM Role Based Service Account (IRSA) for AWS PCA Issuer plugin](#setup-iam-role-based-service-account-irsa-for-aws-pca-issuer-plugin)
    - [IAM Policy creation](#iam-policy-creation)
    - [Create IAM Roles bound to service account IRSA](#create-iam-roles-bound-to-service-account-irsa)
  - [Install aws-privateca-issuer plugin using the ServiceAccount aws-pca-issuer](#install-aws-privateca-issuer-plugin-using-the-serviceaccount-aws-pca-issuer)
  - [Create Certificate Kubernetes Secrets](#create-certificate-kubernetes-secrets)
    - [Create Issuer objects](#create-issuer-objects)
    - [Create Certificate objects](#create-certificate-objects)
      - [Management server certificate](#management-server-certificate)
        - [Validation mgmt cert](#validation-mgmt-cert)
      - [Telemetry Gateway certificate](#telemetry-gateway-certificate)
        - [Validation telemetry gateway cert](#validation-telemetry-gateway-cert)
      - [Create Gloo Agent Certificate in workload cluster](#create-gloo-agent-certificate-in-workload-cluster)
        - [Validation agent cert](#validation-agent-cert)
  - [Install Gloo Mesh mgmt server components with custom CA certificate secrets](#install-gloo-mesh-mgmt-server-components-with-custom-ca-certificate-secrets)
    - [pre-req Create enterprise license Secret in mgmt cluster](#pre-req-create-enterprise-license-secret-in-mgmt-cluster)
    - [Install CRDs](#install-crds)
    - [Install Gloo Mesh mgmt server controlplane components](#install-gloo-mesh-mgmt-server-controlplane-components)
  - [Install Gloo Mesh agent](#install-gloo-mesh-agent)
    - [Register agent using KubernetesCluster object in mgmt cluster](#register-agent-using-kubernetescluster-object-in-mgmt-cluster)
    - [Install CRDs in workload cluster](#install-crds-in-workload-cluster)
    - [Get LB Addresses of mgmt server and Telemetry Gateway](#get-lb-addresses-of-mgmt-server-and-telemetry-gateway)
    - [Install Gloo Mesh agent and telemetry components in workload cluster](#install-gloo-mesh-agent-and-telemetry-components-in-workload-cluster)
    - [validate using meshctl CLI](#validate-using-meshctl-cli)

<!-- TOC end -->

<!-- TOC --><a name="mtls-relay-setup-with-bring-your-own-ca"></a>

# mTLS relay setup with bring your own CA

One of the options of setting up mTLS agent-server relay communication is to store the CA signing certificate and key with your own PKI provider. You then have the option to generate the gloo mgmt server and gloo agent TLS certificates and store them in a Kubernetes secret. To automate the process you may use a tool, such as cert-manager, to automatically issue and rotate TLS certificates for you.

When the Gloo agent tries to connect to the Gloo management server for the first time, the agent presents the client TLS certificate to prove its identity. Because a client TLS certificate is present during the initial connection between the Gloo management server and the agent, no relay identity tokens are required in this setup.

In the following example we use AWS Private CA to setup the external PKI and then use cert manager to manage the certificate lifecycle.

<!-- TOC --><a name="cluster-setup"></a>
## Cluster setup

<!-- TOC --><a name="setup-env-variables"></a>
### Setup env variables

```bash
MGMT_CLUSTER=gloo-mesh-mgmt-cluster
MGMT_CLUSTER_REGION=us-west-2
WORKLOAD_CLUSTER_1=gloo-mesh-workload-cluster-1
WORKLOAD_CLUSTER_1_REGION=us-west-1
```

<!-- TOC --><a name="create-clusters"></a>
### Create clusters

```bash
eksctl create cluster --name $MGMT_CLUSTER --region $MGMT_CLUSTER_REGION \
  --spot \
  --version=1.30 \
  --nodes 2 --nodes-min 0 --nodes-max 3 \
  --instance-types t3.large \
  --with-oidc \
  --tags created-by=arka_bhattacharya,team=customer-success

USER_NAME=arka.bhattacharya
kubectl config rename-context \
 "${USER_NAME}@${MGMT_CLUSTER}.${MGMT_CLUSTER_REGION}.eksctl.io" \
 "${MGMT_CLUSTER}"
```

```bash
eksctl create cluster --name $WORKLOAD_CLUSTER_1 --region $WORKLOAD_CLUSTER_1_REGION \
  --spot \
  --version=1.30 \
  --nodes 2 --nodes-min 0 --nodes-max 3 \
  --instance-types t3.large \
  --with-oidc \
  --tags created-by=arka_bhattacharya,team=customer-success

USER_NAME=arka.bhattacharya
kubectl config rename-context \
 "${USER_NAME}@${WORKLOAD_CLUSTER_1}.${WORKLOAD_CLUSTER_1_REGION}.eksctl.io" \
 "${WORKLOAD_CLUSTER_1}"
```

<!-- TOC --><a name="install-cert-manager"></a>
## Install cert manager

```bash
# https://cert-manager.io/docs/installation/helm/
CERT_MANAGER_VERSION=v1.16.1
helm repo add jetstack https://charts.jetstack.io --force-update

helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --version ${CERT_MANAGER_VERSION} \
  --set installCRDs=true \
  --wait;

# verify
kubectl -n cert-manager rollout status deploy/cert-manager;
kubectl -n cert-manager rollout status deploy/cert-manager-cainjector;
kubectl -n cert-manager rollout status deploy/cert-manager-webhook;
```

> We would need to install on both the clusters

<!-- TOC --><a name="create-root-ca-for-gloo-mesh-in-aws-private-ca"></a>
## Create Root CA for Gloo Mesh in AWS Private CA

```bash
#!/bin/bash
set -e

# Purpose:
# Creates one Root CA in AWS Private Certificate Authority(PCA).

# Note: Please feel free to edit the following section as per your need for the CA Subject details.
export COUNTRY="US"
export ORGANIZATION="Solo.io"
export ORGANIZATIONAL_UNIT="Consulting"
export STATE="MA"
export LOCALITY="Boston"

# Note: Please feel free to edit the values for Validity time of the Root cert and the Subordinate cert.
export ROOT_CERT_VALIDITY_IN_DAYS=3650

##
# Process Flow for AWS Private CA setup
# - Create config json file with details for the Certificate Authority.
# - Create CA (Root or Subordinate) in AWS Private CA.
# - Download CSR file corresponding to the newly created Private CA.
# - Issue certificate for the CA with the help of the downloaded CSR and the Private CA ARN.
#   > Note: Use "--certificate-authority-arn" parameter for issuing a cert for Subordinate/Intermediate CA)
# - Import this certificate in AWS Private CA.
##

echo
echo "###########################################################"
echo " Creating Root CA"
echo " Generated and managed by ACM"
echo "###########################################################"
cat <<EOF > ca_config_root_ca.json
{
   "KeyAlgorithm":"RSA_2048",
   "SigningAlgorithm":"SHA256WITHRSA",
   "Subject":{
      "Country":"${COUNTRY}",
      "Organization":"${ORGANIZATION}",
      "OrganizationalUnit":"${ORGANIZATIONAL_UNIT}",
      "State":"${STATE}",
      "Locality":"${LOCALITY}",
      "CommonName":"Root CA"
   }
}
EOF

echo
echo "[INFO] Creates the root private certificate authority (CA)."
# https://docs.aws.amazon.com/cli/latest/reference/acm-pca/create-certificate-authority.html
ROOT_CAARN=$(aws acm-pca create-certificate-authority \
     --certificate-authority-configuration file://ca_config_root_ca.json \
     --certificate-authority-type "ROOT" \
     --idempotency-token 01234567 \
     --output json \
     --tags Key=Name,Value=RootCA | jq -r '.CertificateAuthorityArn')
echo "[INFO] Sleeping for 15 seconds for CA creation to be completed..."
sleep 15
echo "[DEBUG] ARN of Root CA=${ROOT_CAARN}"

echo "[INFO] download Root CA CSR from AWS"
# https://docs.aws.amazon.com/cli/latest/reference/acm-pca/get-certificate-authority-csr.html
aws acm-pca get-certificate-authority-csr \
    --certificate-authority-arn "${ROOT_CAARN}" \
    --output text > root-ca.csr

echo "[INFO] Issue Root Certificate. Valid for ${ROOT_CERT_VALIDITY_IN_DAYS} days"
# https://docs.aws.amazon.com/cli/latest/reference/acm-pca/issue-certificate.html
ROOT_CERTARN=$(aws acm-pca issue-certificate \
    --certificate-authority-arn "${ROOT_CAARN}" \
    --csr fileb://root-ca.csr \
    --signing-algorithm "SHA256WITHRSA" \
    --template-arn arn:aws:acm-pca:::template/RootCACertificate/V1 \
    --validity Value=${ROOT_CERT_VALIDITY_IN_DAYS},Type="DAYS" \
    --idempotency-token 1234567 \
    --output json | jq -r '.CertificateArn')
echo "[INFO] Sleeping for 15 seconds for cert issuance to be completed..."
sleep 15
echo "[DEBUG] ARN of Root Certificate=${ROOT_CERTARN}"

echo "[INFO] Retrieves root certificate from private CA and save locally as root-cert.pem"
# https://docs.aws.amazon.com/cli/latest/reference/acm-pca/get-certificate.html
aws acm-pca get-certificate \
    --certificate-authority-arn "${ROOT_CAARN}" \
    --certificate-arn "${ROOT_CERTARN}" \
    --output text > root-cert.pem

echo "[INFO] Import the signed Private CA certificate for the CA specified by the ARN into ACM PCA"
# https://docs.aws.amazon.com/cli/latest/reference/acm-pca/import-certificate-authority-certificate.html
aws acm-pca import-certificate-authority-certificate \
    --certificate-authority-arn "${ROOT_CAARN}" \
    --certificate fileb://root-cert.pem
echo "-----------------------------------------------------------"
echo "ARN of Root CA is ${ROOT_CAARN}"
echo "-----------------------------------------------------------"
```

<!-- TOC --><a name="setup-iam-role-based-service-account-irsa-for-aws-pca-issuer-plugin"></a>
## Setup IAM Role Based Service Account (IRSA) for AWS PCA Issuer plugin

<!-- TOC --><a name="iam-policy-creation"></a>
### IAM Policy creation

```bash
echo "ROOT_CAARN = ${ROOT_CAARN}"
cat <<EOF > AWSPCAIssuerPolicy.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "awspcaissuer",
      "Action": [
        "acm-pca:DescribeCertificateAuthority",
        "acm-pca:GetCertificate",
        "acm-pca:IssueCertificate"
      ],
      "Effect": "Allow",
      "Resource": [
        "${ROOT_CAARN}"
        ]
    }
  ]
}
EOF

POLICY_ARN=$(aws iam create-policy \
    --policy-name AWSPCAIssuerPolicy \
    --policy-document file://AWSPCAIssuerPolicy.json \
    --output json | jq -r '.Policy.Arn')

echo "IAM POLICY_ARN = ${POLICY_ARN}"
```

<!-- TOC --><a name="create-iam-roles-bound-to-service-account-irsa"></a>
### Create IAM Roles bound to service account IRSA

```bash
CURRENT_CLUSTER="${MGMT_CLUSTER}"
echo; echo "IAM POLICY_ARN = ${POLICY_ARN}, CURRENT_CLUSTER= ${CURRENT_CLUSTER}, MGMT_CLUSTER_REGION= ${MGMT_CLUSTER_REGION}"; echo

# Enable the IAM OIDC Provider for the cluster - if not already enabled
eksctl utils associate-iam-oidc-provider \
    --cluster=${CURRENT_CLUSTER} \
    --region ${MGMT_CLUSTER_REGION} \
    --approve;

# Create IAM role bound to a service account
eksctl create iamserviceaccount --cluster=${CURRENT_CLUSTER} --region ${MGMT_CLUSTER_REGION} \
    --attach-policy-arn=${POLICY_ARN} \
    --role-name "ServiceAccountRolePrivateCA-${CURRENT_CLUSTER}" \
    --namespace=cert-manager \
    --override-existing-serviceaccounts \
    --name="aws-pca-issuer" \
    --approve;
```

```bash
CURRENT_CLUSTER="${WORKLOAD_CLUSTER_1}"
echo; echo "IAM POLICY_ARN = ${POLICY_ARN}, WORKLOAD_CLUSTER_1_REGION= ${WORKLOAD_CLUSTER_1_REGION}, CURRENT_CLUSTER= ${CURRENT_CLUSTER}"; echo;

# Enable the IAM OIDC Provider for the cluster - if not already enabled
eksctl utils associate-iam-oidc-provider \
    --cluster=${CURRENT_CLUSTER} \
    --region ${WORKLOAD_CLUSTER_1_REGION} \
    --approve;

eksctl create iamserviceaccount --cluster=${CURRENT_CLUSTER} --region ${WORKLOAD_CLUSTER_1_REGION} \
    --attach-policy-arn=${POLICY_ARN} \
    --role-name "ServiceAccountRolePrivateCA-${CURRENT_CLUSTER}" \
    --namespace=cert-manager \
    --override-existing-serviceaccounts \
    --name="aws-pca-issuer" \
    --approve;
```

<!-- TOC --><a name="install-aws-privateca-issuer-plugin-using-the-serviceaccount-aws-pca-issuer"></a>
## Install aws-privateca-issuer plugin using the ServiceAccount aws-pca-issuer

```bash
# We are installing the plugin in the same namespace as cert-manager
export PCA_NAMESPACE=cert-manager
# latest version https://github.com/cert-manager/aws-privateca-issuer/releases
export AWSPCA_ISSUER_TAG=v1.4.0

# Install AWS Private CA Issuer Plugin 
# https://github.com/cert-manager/aws-privateca-issuer/#setup
helm repo add awspca https://cert-manager.github.io/aws-privateca-issuer
helm repo update
helm upgrade --install aws-pca-issuer awspca/aws-privateca-issuer \
    --namespace ${PCA_NAMESPACE} \
    --set image.tag=${AWSPCA_ISSUER_TAG} \
    --set serviceAccount.create=false \
    --set serviceAccount.name="aws-pca-issuer" \
    --wait;

# Verify deployment status
kubectl -n ${PCA_NAMESPACE} \
    rollout status deploy/aws-pca-issuer-aws-privateca-issuer;
```

> We would need to install on both the clusters

<!-- TOC --><a name="create-certificate-kubernetes-secrets"></a>
## Create Certificate Kubernetes Secrets

<!-- TOC --><a name="create-issuer-objects"></a>
### Create Issuer objects

```bash
# edit the var if your CA is in a different region
export CA_REGION=us-east-2

for CURRENT_CLUSTER in ${MGMT_CLUSTER} ${WORKLOAD_CLUSTER_1}
do
kubectl --context ${CURRENT_CLUSTER} create namespace gloo-mesh;
cat << EOF | kubectl apply --context ${CURRENT_CLUSTER} -f -
apiVersion: awspca.cert-manager.io/v1beta1
kind: AWSPCAIssuer
metadata:
  name: aws-pca-issuer-gloo-mesh
  namespace: gloo-mesh
spec:
  arn: ${ROOT_CAARN}
  region: ${CA_REGION}
EOF
done
```

<!-- TOC --><a name="create-certificate-objects"></a>
### Create Certificate objects

<!-- TOC --><a name="management-server-certificate"></a>
#### Management server certificate

```bash
kubectl apply --context $MGMT_CLUSTER -f - << EOF
kind: Certificate
apiVersion: cert-manager.io/v1
metadata:
  name: gloo-mesh-mgmt-server-tls-cert
  namespace: gloo-mesh
spec:
  issuerRef:
# ---------------- Issuer for Gloo Mesh certs ---------------------------
    group: awspca.cert-manager.io
    kind: AWSPCAIssuer
    name: aws-pca-issuer-gloo-mesh
# ---------------- Issuer for Gloo Mesh certs ---------------------------
# ---------------- K8s secret that will be created ---------------------
  secretName: gloo-mesh-mgmt-server-tls-secret
# ---------------- Certificate details ---------------------------------
  duration: 8760h # 365 days
  renewBefore: 360h # 15 days
  commonName: gloo-mesh-mgmt-server.gloo-mesh
  dnsNames:
    - "gloo-mesh-mgmt-server.gloo-mesh"
  usages:
    - server auth
    - client auth
    - digital signature
    - key encipherment
  privateKey:
    algorithm: "RSA"
    size: 2048
# ---------------- Certificate details ---------------------------------
EOF
```

<!-- TOC --><a name="validation-mgmt-cert"></a>
##### Validation mgmt cert

```bash
kubectl --context $MGMT_CLUSTER -n gloo-mesh get certificate gloo-mesh-mgmt-server-tls-cert -o wide
```

```bash
NAME                             READY   SECRET                             ISSUER                     STATUS                                          AGE
gloo-mesh-mgmt-server-tls-cert   True    gloo-mesh-mgmt-server-tls-secret   aws-pca-issuer-gloo-mesh   Certificate is up to date and has not expired   4s
```

<!-- TOC --><a name="telemetry-gateway-certificate"></a>
#### Telemetry Gateway certificate

```bash
kubectl apply --context $MGMT_CLUSTER -f - << EOF
kind: Certificate
apiVersion: cert-manager.io/v1
metadata:
  name: gloo-mesh-telemetry-gateway-tls-cert
  namespace: gloo-mesh
spec:
  issuerRef:
# ---------------- Issuer for Gloo Mesh certs ---------------------------
    group: awspca.cert-manager.io
    kind: AWSPCAIssuer
    name: aws-pca-issuer-gloo-mesh
# ---------------- Issuer for Gloo Mesh certs ---------------------------
# ---------------- K8s secret that will be created ---------------------
  secretName: gloo-telemetry-gateway-tls-secret
# ---------------- Certificate details ---------------------------------
  duration: 8760h # 365 days
  renewBefore: 360h # 15 days
  commonName: gloo-telemetry-gateway.gloo-mesh
  dnsNames:
    - "gloo-telemetry-gateway.gloo-mesh"
  usages:
    - server auth
    - client auth
    - digital signature
    - key encipherment
  privateKey:
    algorithm: "RSA"
    size: 2048
# ---------------- Certificate details ---------------------------------
EOF
```

<!-- TOC --><a name="validation-telemetry-gateway-cert"></a>
##### Validation telemetry gateway cert

```bash
kubectl --context $MGMT_CLUSTER -n gloo-mesh get certificate gloo-mesh-telemetry-gateway-tls-cert -o wide
```

```bash
NAME                                   READY   SECRET                              ISSUER                     STATUS                                          AGE
gloo-mesh-telemetry-gateway-tls-cert   True    gloo-telemetry-gateway-tls-secret   aws-pca-issuer-gloo-mesh   Certificate is up to date and has not expired   6s
```

<!-- TOC --><a name="create-gloo-agent-certificate-in-workload-cluster"></a>
#### Create Gloo Agent Certificate in workload cluster

```bash
kubectl apply --context ${WORKLOAD_CLUSTER_1} -f - << EOF
kind: Certificate
apiVersion: cert-manager.io/v1
metadata:
  name: gloo-mesh-agent-tls-cert
  namespace: gloo-mesh
spec:
  issuerRef:
# ---------------- Issuer for Gloo Mesh certs ---------------------------
    group: awspca.cert-manager.io
    kind: AWSPCAIssuer
    name: aws-pca-issuer-gloo-mesh
# ---------------- Issuer for Gloo Mesh certs ---------------------------
# ---------------- K8s secret that will be created ---------------------
  secretName: gloo-mesh-agent-tls-secret
# ---------------- Certificate details ---------------------------------
  duration: 8760h # 365 days
  renewBefore: 360h # 15 days
  commonName: "${WORKLOAD_CLUSTER_1}"
  dnsNames:
    # Must match the cluster name used in the helm chart install
    - "${WORKLOAD_CLUSTER_1}"
  usages:
    - server auth
    - client auth
    - digital signature
    - key encipherment
  privateKey:
    algorithm: "RSA"
    size: 2048
# ---------------- Certificate details ---------------------------------
EOF
```

Create the `relay-root-tls-secret` (required by the collector) for cross cluster OTel collector-gateway communications.

```bash
kubectl apply --context ${WORKLOAD_CLUSTER_1} -f - << EOF
kind: Certificate
apiVersion: cert-manager.io/v1
metadata:
  name: gloo-mesh-collector-tls-cert
  namespace: gloo-mesh
spec:
  issuerRef:
# ---------------- Issuer for Gloo Mesh certs ---------------------------
    group: awspca.cert-manager.io
    kind: AWSPCAIssuer
    name: aws-pca-issuer-gloo-mesh
# ---------------- Issuer for Gloo Mesh certs ---------------------------
# ---------------- K8s secret that will be created ---------------------
  secretName: relay-root-tls-secret
# ---------------- Certificate details ---------------------------------
  duration: 8760h # 365 days
  renewBefore: 360h # 15 days
  commonName: gloo-mesh-telemetry-collector
  usages:
    - server auth
    - client auth
  privateKey:
    algorithm: "RSA"
    size: 2048
# ---------------- Certificate details ---------------------------------
EOF
```

<!-- TOC --><a name="validation-agent-cert"></a>
##### Validation agent cert

```bash
kubectl --context $WORKLOAD_CLUSTER_1 -n gloo-mesh get certificate gloo-mesh-agent-tls-cert -o wide
```

```bash
NAME                       READY   SECRET                       ISSUER                     STATUS                                          AGE
gloo-mesh-agent-tls-cert   True    gloo-mesh-agent-tls-secret   aws-pca-issuer-gloo-mesh   Certificate is up to date and has not expired   4s
```

<!-- TOC --><a name="install-gloo-mesh-mgmt-server-components-with-custom-ca-certificate-secrets"></a>
## Install Gloo Mesh mgmt server components with custom CA certificate secrets

set env var

```bash
export GLOO_MESH_ENTERPRISE_VERSION=2.6.5
```

<!-- TOC --><a name="pre-req-create-enterprise-license-secret-in-mgmt-cluster"></a>
### pre-req Create enterprise license Secret in mgmt cluster

```bash
kubectl apply --context ${MGMT_CLUSTER} -f -<< EOF
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

<!-- TOC --><a name="install-crds"></a>
### Install CRDs

```bash
helm upgrade -i gloo-platform-crds gloo-platform/gloo-platform-crds \
  --version="${GLOO_MESH_ENTERPRISE_VERSION}" \
  --kube-context "${MGMT_CLUSTER}" \
  --namespace=gloo-mesh --wait
```

<!-- TOC --><a name="install-gloo-mesh-mgmt-server-controlplane-components"></a>
### Install Gloo Mesh mgmt server controlplane components

```bash
helm upgrade -i gloo-platform gloo-platform/gloo-platform \
  --version="${GLOO_MESH_ENTERPRISE_VERSION}" \
  --namespace=gloo-mesh \
  --kube-context "${MGMT_CLUSTER}" \
  --wait \
  --values - <<EOF
licensing:
  licenseSecretName: gloo-mesh-enterprise-license-keys
common:
  cluster: "${MGMT_CLUSTER}"
glooMgmtServer:
  enabled: true
  relay:
    # Use the certificate present in the K8s Secret
    tlsSecret:
      name: gloo-mesh-mgmt-server-tls-secret
    # Don't create default self signed cert-token
    disableCa: true
    disableCaCertGeneration: true
    disableTokenGeneration: true
  serviceType: LoadBalancer
  serviceOverrides:
    metadata:
      annotations:
        # using the default AWS Cloud in-tree controller
        service.beta.kubernetes.io/aws-load-balancer-type: "nlb"
        # uncomment if using the default AWS LB controller
        #service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: "ip"
        #service.beta.kubernetes.io/aws-load-balancer-type: "external"
        #service.beta.kubernetes.io/aws-load-balancer-scheme: internet-facing
  # TODO: check if these values are default
  image:
    registry: gcr.io/gloo-mesh
    repository: gloo-mesh-mgmt-server
  # A list of image pull secrets in the same namespace that store the credentials that are used to access a private container imagregistry. The image registry stores the container image that you want to use for this component.
  #imagePullSecrets: []
prometheus:
  enabled: true
  skipAutoMigration: true
  #imagePullSecrets: []
  # - name: "image-pull-secret"
  configmapReload:
    prometheus:
      image:
        repository: quay.io/prometheus-operator/prometheus-config-reloader
  server:
    image:
      repository: quay.io/prometheus/prometheus
redis:
  deployment:
    enabled: true
    # TODO: check if these values are default
    image:
      registry: gcr.io/gloo-mesh
      repository: redis
    #imagePullSecrets: []
glooUi:
  enabled: true
  # TODO: check if these values are default
  image:
    registry: gcr.io/gloo-mesh
    repository: gloo-mesh-apiserver
  # A list of image pull secrets in the same namespace that store the credentials that are used to access a private container imagregistry. The image registry stores the container image that you want to use for this component.
  #imagePullSecrets: []
  sidecars:
    console:
      # TODO: check if these values are default
      image:
        registry: gcr.io/gloo-mesh
        repository: gloo-mesh-ui
    envoy:
      # TODO: check if these values are default
      image:
        registry: gcr.io/gloo-mesh
        repository: gloo-mesh-envoy
telemetryGateway:
  enabled: true
  # Notice how also the telemetry gateway needs a load balancer type of service reachable from the workload cluster
  service:
    type: LoadBalancer
    # https://github.com/open-telemetry/opentelemetry-helm-charts/blob/main/charts/opentelemetry-collector/values.yaml#L479
    annotations:
      # using the default AWS Cloud in-tree controller
      service.beta.kubernetes.io/aws-load-balancer-type: "nlb"
      # uncomment if using the default AWS LB controller
      #service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: "ip"
      #service.beta.kubernetes.io/aws-load-balancer-type: "external"
      #service.beta.kubernetes.io/aws-load-balancer-scheme: internet-facing
  # TODO: check if these values are default
  image:
    repository: gcr.io/gloo-mesh/gloo-otel-collector
  #imagePullSecrets: []
telemetryGatewayCustomization:
  disableCertGeneration: true
telemetryCollector:
  enabled: true
  config:
    exporters:
      otlp:
        endpoint: gloo-telemetry-gateway.gloo-mesh:4317
  image:
    # TODO: double check if this value is default
    repository: gcr.io/gloo-mesh/gloo-otel-collector
  #imagePullSecrets: []
telemetryCollectorCustomization:
  serverName: "gloo-telemetry-gateway.gloo-mesh"
EOF
```

<!-- TOC --><a name="install-gloo-mesh-agent"></a>
## Install Gloo Mesh agent

<!-- TOC --><a name="register-agent-using-kubernetescluster-object-in-mgmt-cluster"></a>
### Register agent using KubernetesCluster object in mgmt cluster

```bash
kubectl apply --context ${MGMT_CLUSTER} -f -<< EOF
apiVersion: admin.gloo.solo.io/v2
kind: KubernetesCluster
metadata:
  name: "${WORKLOAD_CLUSTER_1}"
  namespace: gloo-mesh
spec:
  clusterDomain: cluster.local
EOF
```

<!-- TOC --><a name="install-crds-in-workload-cluster"></a>
### Install CRDs in workload cluster

```bash
helm upgrade -i gloo-platform-crds gloo-platform/gloo-platform-crds \
  --version="${GLOO_MESH_ENTERPRISE_VERSION}" \
  --kube-context "${WORKLOAD_CLUSTER_1}" \
  --namespace=gloo-mesh --wait
```

<!-- TOC --><a name="get-lb-addresses-of-mgmt-server-and-telemetry-gateway"></a>
### Get LB Addresses of mgmt server and Telemetry Gateway

```bash
# wait for the load balancer to be provisioned
until kubectl get service/gloo-mesh-mgmt-server --output=jsonpath='{.status.loadBalancer}' --context ${MGMT_CLUSTER} -n gloo-mesh | grep "ingress"; do : ; done
until kubectl get service/gloo-telemetry-gateway --output=jsonpath='{.status.loadBalancer}' --context ${MGMT_CLUSTER} -n gloo-mesh | grep "ingress"; do : ; done

# Get the LB addresses
export GLOO_PLATFORM_SERVER_DOMAIN=$(kubectl get svc gloo-mesh-mgmt-server --context ${MGMT_CLUSTER} -n gloo-mesh -o jsonpath='{.status.loadBalancer.ingress[0].*}')
export GLOO_PLATFORM_SERVER_ADDRESS=${GLOO_PLATFORM_SERVER_DOMAIN}:$(kubectl get svc gloo-mesh-mgmt-server --context ${MGMT_CLUSTER} -n gloo-mesh -o jsonpath='{.spec.ports[?(@.name=="grpc")].port}')
export GLOO_TELEMETRY_GATEWAY=$(kubectl get svc gloo-telemetry-gateway --context ${MGMT_CLUSTER} -n gloo-mesh -o jsonpath='{.status.loadBalancer.ingress[0].*}'):$(kubectl get svc gloo-telemetry-gateway --context ${MGMT_CLUSTER} -n gloo-mesh -o jsonpath='{.spec.ports[?(@.name=="otlp")].port}')

# Print the values
echo "Mgmt Plane Address: $GLOO_PLATFORM_SERVER_ADDRESS"
echo "Metrics Gateway Address: $GLOO_TELEMETRY_GATEWAY"
```

<!-- TOC --><a name="install-gloo-mesh-agent-and-telemetry-components-in-workload-cluster"></a>
### Install Gloo Mesh agent and telemetry components in workload cluster

```bash
helm upgrade -i gloo-agent gloo-platform/gloo-platform \
  --version="${GLOO_MESH_ENTERPRISE_VERSION}" \
  --namespace gloo-mesh \
  --kube-context "${WORKLOAD_CLUSTER_1}" \
  --values - << EOF
common:
  cluster: $WORKLOAD_CLUSTER_1
glooAgent:
  enabled: true
  relay:
    # Because the glooAgent is running on a different cluster than the management server, the address needs to resolve to where the Mserver is:
    # serverAddress: <<REPLACE-WITH-gloo-mesh-mgmt-server-ADDRESS>>:9900
    serverAddress: $GLOO_PLATFORM_SERVER_ADDRESS
    # SNI name in the authority/host header used to connect to relay forwarding server. Must match server certificate CommonName.
    authority: "gloo-mesh-mgmt-server.gloo-mesh"
    clientTlsSecret:
      name: gloo-mesh-agent-tls-secret
  image:
    # TODO: check if these values are by default to remove from here:
    registry: gcr.io/gloo-mesh
    repository: gloo-mesh-agent
  # A list of image pull secrets in the same namespace that store the credentials that are used to access a private container imagregistry. The image registry stores the container image that you want to use for this component.
  #imagePullSecrets: []
telemetryCollector:
  enabled: true
  config:
    exporters:
      otlp:
        # Because the glooAgent is running on a different cluster than the management server, the address needs to resolve to where thMP server is:
        # endpoint: <<REPLACE-WITH-gloo-telemetry-gateway-ADDRESS>>:4317
        endpoint: $GLOO_TELEMETRY_GATEWAY
  image:
    # TODO: check if these values are by default to remove from here:
    repository: gcr.io/gloo-mesh/gloo-otel-collector
  #imagePullSecrets: []
telemetryCollectorCustomization:
  serverName: "gloo-telemetry-gateway.gloo-mesh"
EOF
```

<!-- TOC --><a name="validate-using-meshctl-cli"></a>
### validate using meshctl CLI

```bash
meshctl check ${MGMT_CLUSTER}
```

Expected output

```bash
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

🟢 Mgmt server connectivity to workload agents

Cluster                      | Registered | Connected Pod
gloo-mesh-workload-cluster-1 | true       | gloo-mesh/gloo-mesh-mgmt-server-7fc94f5578-wnmfv

Connected Pod                                    | Clusters
gloo-mesh/gloo-mesh-mgmt-server-7fc94f5578-wnmfv | 1
```
