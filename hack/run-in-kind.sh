#!/bin/bash

set -eu

KUBE_VERSION=v1.33.1
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
CLUSTER_NAME_PREFIX=cluster
KUBECONFIG_PREFIX=~/.kube/${CLUSTER_NAME_PREFIX}
PRE_LOAD_IMAGES_EXTRAS_FILE=${SCRIPT_DIR}/preload-extras.txt
INGRESS=${INGRESS:-ingressNginx}
SUBMARINER_BROKER_NS=addon-submariner-broker
SUBMARINER_OPERATOR_NS=submariner-operator

verifyBinariesExist() {
  echo "Verify binaries exist"
  if ! command -v jq &> /dev/null
  then
      echo "jq could not be found"
      exit 1
  fi
  if ! command -v kind &> /dev/null
  then
      echo "kind could not be found"
      exit 1
  fi
  if ! command -v helm &> /dev/null
  then
      echo "helm could not be found"
      exit 1
  fi
  if ! command -v kubectl &> /dev/null
  then
      echo "kubectl could not be found"
      exit 1
  fi
  if ! command -v argocd &> /dev/null
  then
      echo "argocd could not be found"
      exit 1
  fi
  if ! command -v clusteradm &> /dev/null
  then
    echo "clusteradm could not be found"
    exit 1
  fi
}

pullNeededImagesFromFile () {
  IMAGES_FILE="$1"

  echo ""
  echo "Pull images from ${IMAGES_FILE} that we know will be needed, especially from docker.io which minimize re-pulls"
  while read -r image; do
    echo "Checking ${image}"
    # Check if the image exists using Docker manifest inspect
    docker inspect "${image}" > /dev/null 2>&1 \
      || docker pull --platform linux/arm64 --platform linux/amd64 "${image}" \
      || exit 1
  done <"${IMAGES_FILE}"
}

preloadImagesFromFile () {
  IMAGES_FILE="$1"

  mkdir -p tmp
  echo ""
  echo "Preload images from ${IMAGES_FILE} that we know will be needed, especially from docker.io which minimize re-pulls"
  while read -r p; do
    docker save --platform linux/arm64 --platform linux/amd64 "${p}" > tmp/image.tar \
    || exit 1
    kind --name "${CLUSTER_NAME}" load image-archive tmp/image.tar \
    || exit 1
  done <"${IMAGES_FILE}"
}

startupCluster() {
  touch "${KUBECONFIG}" || exit 1

  echo ""
  echo "Delete cluster if it exists"
  kind delete cluster --name "${CLUSTER_NAME}" \
    || exit 1

  echo ""
  GIT_REVISION=$(git rev-parse --abbrev-ref HEAD)
  echo "Current git branch is ${GIT_REVISION}"

  if test -f "${PRE_LOAD_IMAGES_FILE}"; then
    pullNeededImagesFromFile "${PRE_LOAD_IMAGES_FILE}"
  fi

  if test -f "${PRE_LOAD_IMAGES_EXTRAS_FILE}"; then
    pullNeededImagesFromFile "${PRE_LOAD_IMAGES_EXTRAS_FILE}"
  fi

  echo ""
  echo "Create cluster from config ${KIND_CONFIG} with name ${CLUSTER_NAME}"
  kind create cluster \
    --config="${SCRIPT_DIR}/${KIND_CONFIG}" \
    --name "${CLUSTER_NAME}" \
    --kubeconfig "${KUBECONFIG}" \
    --image "kindest/node:${KUBE_VERSION}" \
    --wait 120s \
    || exit 1

  chmod 600 "${KUBECONFIG}" || exit 1

  echo ""
  echo "Wait for cluster to start"
  while ! kubectl --kubeconfig "${KUBECONFIG}" cluster-info
  do
    echo "Try again"
    sleep 5
  done

  if test -f "${PRE_LOAD_IMAGES_FILE}"; then
    preloadImagesFromFile "${PRE_LOAD_IMAGES_FILE}"
  fi

  if test -f "${PRE_LOAD_IMAGES_EXTRAS_FILE}"; then
    preloadImagesFromFile "${PRE_LOAD_IMAGES_EXTRAS_FILE}"
  fi

  echo "Deleting temporary directory"
  rm -R tmp || echo "Temporary directory might not exist"

  echo ""
  echo "Preinstall prometheus service monitor CRD"
  PROM_VERSION=$(yq '.prometheus.version' < "../clusters/hub/_start/values.yaml")
  kubectl apply --server-side=true \
   -f "https://raw.githubusercontent.com/prometheus-community/helm-charts/refs/tags/kube-prometheus-stack-${PROM_VERSION}/charts/kube-prometheus-stack/charts/crds/crds/crd-servicemonitors.yaml"

  echo ""
  echo "Preinstall cert-manager CRD"
  CERT_MANAGER_VERSION=$(yq '.certmanager.version' < "../clusters/hub/_start/values.yaml")
  kubectl apply --server-side=true \
   -f "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.crds.yaml"

  echo ""
  echo "Create argocd namespace"
  kubectl --kubeconfig "${KUBECONFIG}" \
    create namespace argocd \
    || exit 1

  echo ""
  echo "Install argocd"
  helm dependency update \
    ./argo-install \
    || exit 1
  helm --kubeconfig "${KUBECONFIG}" \
    install -n argocd \
    argocd ./argo-install \
    || exit 1

  echo ""
  echo "Wait for argocd to start"
  DEPLOYMENTS=$(kubectl \
    --kubeconfig "${KUBECONFIG}" \
    -n argocd \
    get deploy -o json | jq -r '.items[].metadata.name' | tr '\n' ' ')

  kubectl \
   --kubeconfig "${KUBECONFIG}" \
   --namespace=argocd \
    wait deployment ${DEPLOYMENTS} \
    --for condition=Available=True \
    --timeout=180s \
    || exit 1

  kubectl config set-context --current --namespace=argocd
}

pushd "${SCRIPT_DIR}" \
  || exit 1

verifyBinariesExist

echo ""
echo "Start cluster hub"
KIND_CONFIG=kind-cluster-hub.yaml
CLUSTER_NAME="${CLUSTER_NAME_PREFIX}-hub"
KUBECONFIG="${KUBECONFIG_PREFIX}-hub"
PRE_LOAD_IMAGES_FILE=${SCRIPT_DIR}/preload-${CLUSTER_NAME}.txt

startupCluster

echo ""
echo "Init OCM on cluster hub"
clusteradm init --wait
OCM_JOIN_CMD=$(clusteradm get token | grep clusteradm)

##### CLUSTER 1
echo ""
echo "Start cluster 1"
KIND_CONFIG=kind-cluster-1.yaml
CLUSTER_NAME="${CLUSTER_NAME_PREFIX}-1"
KUBECONFIG="${KUBECONFIG_PREFIX}-1"
PRE_LOAD_IMAGES_FILE=${SCRIPT_DIR}/preload-${CLUSTER_NAME}.txt

startupCluster

echo ""
echo "Join ${CLUSTER_NAME} to hub"
eval "$(echo ${OCM_JOIN_CMD} --force-internal-endpoint-lookup --wait | sed "s/<cluster_name>/${CLUSTER_NAME}/g")"
echo "Accept join of ${CLUSTER_NAME}"
KUBECONFIG="${KUBECONFIG_PREFIX}-hub" \
  clusteradm accept --clusters ${CLUSTER_NAME} --wait

KUBECONFIG="${KUBECONFIG_PREFIX}-hub" \
  kubectl wait managedclusters ${CLUSTER_NAME} --for condition=ManagedClusterJoined=True

# Install ocm application
echo ""
echo "Install OCM application"
helm --kubeconfig "${KUBECONFIG}" \
  upgrade -i \
  start ./start \
  --set "targetRevision=${GIT_REVISION}" \
  --set "ocmWorker.use=true" \
  || exit 1

######## CLUSTER 2
echo ""
echo "Start cluster 2"
KIND_CONFIG=kind-cluster-2.yaml
CLUSTER_NAME="${CLUSTER_NAME_PREFIX}-2"
KUBECONFIG="${KUBECONFIG_PREFIX}-2"
PRE_LOAD_IMAGES_FILE=${SCRIPT_DIR}/preload-${CLUSTER_NAME}.txt

startupCluster

# Install ocm application
echo ""
echo "Install OCM application"
helm --kubeconfig "${KUBECONFIG}" \
  upgrade -i \
  start ./start \
  --set "targetRevision=${GIT_REVISION}" \
  --set "ocmWorker.use=true" \
  || exit 1

echo ""
echo "Join ${CLUSTER_NAME} to hub"
eval "$(echo "${OCM_JOIN_CMD} --force-internal-endpoint-lookup --wait" | sed "s/<cluster_name>/${CLUSTER_NAME}/g")"
echo "Accept join of ${CLUSTER_NAME}"
KUBECONFIG="${KUBECONFIG_PREFIX}-hub" \
  clusteradm accept --clusters ${CLUSTER_NAME} --wait

KUBECONFIG="${KUBECONFIG_PREFIX}-hub" \
  kubectl wait managedclusters ${CLUSTER_NAME} --for condition=ManagedClusterJoined=True

##### HUB
KUBECONFIG="${KUBECONFIG_PREFIX}-hub"
echo ""
echo "Show managed clusters in hub"
kubectl get managedclusters --all-namespaces

# Install hub application
echo ""
echo "Install hub root application"
helm --kubeconfig "${KUBECONFIG}" \
  upgrade -i \
  start ./start \
  --set "targetRevision=${GIT_REVISION}" \
  --set "root.use=true" \
  || exit 1

##### Submariner
helm repo add submariner-latest https://submariner-io.github.io/submariner-charts/charts
SUBMARINER_BROKER_TOKEN_SECRET=submariner-broker-submariner-k8s-broker-client-token
echo ""
echo "Wait for submariner-k8s-broker to startup"
while : ; do
  kubectl --kubeconfig "${KUBECONFIG_PREFIX}-hub" \
    get ns ${SUBMARINER_BROKER_NS} && break
  sleep 5
done

while : ; do
  kubectl --kubeconfig "${KUBECONFIG_PREFIX}-hub" \
    get secret -n ${SUBMARINER_BROKER_NS} ${SUBMARINER_BROKER_TOKEN_SECRET} && break
  sleep 5
done

echo ""
echo "Fetch stuff from hub to be able to join worker clusters"
export SUBMARINER_BROKER_CA=$(kubectl --kubeconfig "${KUBECONFIG_PREFIX}-hub" \
    -n "${SUBMARINER_BROKER_NS}" \
    get secret ${SUBMARINER_BROKER_TOKEN_SECRET} \
    -o jsonpath="{.data['ca\.crt']}")
export SUBMARINER_BROKER_TOKEN=$(kubectl --kubeconfig "${KUBECONFIG_PREFIX}-hub" \
    -n "${SUBMARINER_BROKER_NS}" \
    get secret ${SUBMARINER_BROKER_TOKEN_SECRET} \
    -o jsonpath="{.data.token}" \
       | base64 --decode)
export SUBMARINER_BROKER_URL=$(kubectl --kubeconfig "${KUBECONFIG_PREFIX}-hub" \
    -n default get endpoints kubernetes \
    -o jsonpath="{.subsets[0].addresses[0].ip}:{.subsets[0].ports[?(@.name=='https')].port}")

echo "SUBMARINER_BROKER_CA=${SUBMARINER_BROKER_CA}"
echo "SUBMARINER_BROKER_TOKEN=${SUBMARINER_BROKER_TOKEN}"
echo "SUBMARINER_BROKER_URL=${SUBMARINER_BROKER_URL}"

##### Submariner cluster-1
echo ""
CLUSTER_ID="1"
echo "Join cluster ${CLUSTER_ID} to submariner"
helm --kubeconfig "${KUBECONFIG_PREFIX}-${CLUSTER_ID}" \
  install submariner-operator submariner-latest/submariner-operator \
    -f "${SCRIPT_DIR}/../clusters/hub/submariner-operator/values.yaml" \
    -f "${SCRIPT_DIR}/../clusters/hub/submariner-operator/values-cluster-${CLUSTER_ID}.yaml" \
        --create-namespace \
        --namespace "${SUBMARINER_OPERATOR_NS}" \
        --set broker.server="${SUBMARINER_BROKER_URL}" \
        --set broker.token="${SUBMARINER_BROKER_TOKEN}" \
        --set broker.ca="${SUBMARINER_BROKER_CA}" \
  || exit 1

##### Submariner cluster-2
echo ""
CLUSTER_ID="2"
echo "Join cluster ${CLUSTER_ID} to submariner"
helm --kubeconfig "${KUBECONFIG_PREFIX}-${CLUSTER_ID}" \
  install submariner-operator submariner-latest/submariner-operator \
    -f "${SCRIPT_DIR}/../clusters/hub/submariner-operator/values.yaml" \
    -f "${SCRIPT_DIR}/../clusters/hub/submariner-operator/values-cluster-${CLUSTER_ID}.yaml" \
        --create-namespace \
        --namespace "${SUBMARINER_OPERATOR_NS}" \
        --set broker.server="${SUBMARINER_BROKER_URL}" \
        --set broker.token="${SUBMARINER_BROKER_TOKEN}" \
        --set broker.ca="${SUBMARINER_BROKER_CA}" \
  || exit 1
