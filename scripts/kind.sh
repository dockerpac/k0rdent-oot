#!/bin/bash
# SPDX-License-Identifier: Apache-2.0

set +x

KIND_CLUSTER_NAME=${KIND_CLUSTER_NAME:-kind}
echo "Using cluster name: ${KIND_CLUSTER_NAME}"

echo "Fetching latest versions of charts ..."
CALICO_VERSION=$(curl -s "https://api.github.com/repos/projectcalico/calico/releases/latest" | jq -r ".tag_name")
METALLB_VERSION=$(curl -s "https://api.github.com/repos/metallb/metallb/releases/latest" | jq -r ".tag_name")

echo "Using Calico version: ${CALICO_VERSION}"
echo "Using MetalLB version: ${METALLB_VERSION}"

TMP_DIR=${TMPDIR:-/tmp}
KIND_CONFIG_DIR="${TMP_DIR}/kind-config"

#https://github.com/containerd/containerd/blob/main/docs/hosts.md#setup-default-mirror-for-all-registries
REGISTRY_PROXY=${REGISTRY_PROXY:-""}

mkdir -p ${KIND_CONFIG_DIR}

if [ -n "$REGISTRY_PROXY" ]; then
  echo "Configuring with registry proxy: ${REGISTRY_PROXY}"
  cat <<EOF > ${KIND_CONFIG_DIR}/default_hosts.toml
[host."https://${REGISTRY_PROXY}"]
  capabilities = ["pull", "resolve"]
  # skip_verify = true
EOF

  cat <<EOF > ${KIND_CONFIG_DIR}/cluster.yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking:
    disableDefaultCNI: true
nodes:
  - role: control-plane
    extraMounts:
      - hostPath: ${KIND_CONFIG_DIR}/default_hosts.toml
        containerPath: /etc/containerd/certs.d/_default/hosts.toml
        readOnly: true
containerdConfigPatches:
  - |-
    [plugins.'io.containerd.cri.v1.images'.registry]
       config_path = '/etc/containerd/certs.d'
EOF
else
  echo "Configuring without registry proxy"
  cat <<EOF > ${KIND_CONFIG_DIR}/cluster.yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking:
    disableDefaultCNI: true
EOF
fi

echo "Creating Kind cluster: ${KIND_CLUSTER_NAME}"
kind create cluster --name ${KIND_CLUSTER_NAME} --retain --config ${KIND_CONFIG_DIR}/cluster.yaml

echo "Installing Calico ${CALICO_VERSION}..."
until kubectl create -f "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml"; do
  echo "Retrying Calico installation in 5 seconds..."
  sleep 5
done

echo "Installing MetalLB ${METALLB_VERSION}..."
until kubectl apply -f "https://raw.githubusercontent.com/metallb/metallb/${METALLB_VERSION}/config/manifests/metallb-native.yaml"; do
  echo "Retrying MetalLB installation in 5 seconds..."
  sleep 5
done

echo "Waiting for MetalLB controller to be ready..."
kubectl wait pods -n metallb-system -l app=metallb,component=controller --for=condition=Ready --timeout=10m
echo "Waiting for MetalLB speaker to be ready..."
kubectl wait pods -n metallb-system -l app=metallb,component=speaker --for=condition=Ready --timeout=2m

echo "Configuring MetalLB IP pool..."
until GW_IP=$(docker network inspect -f '{{range .IPAM.Config}}{{.Gateway}}{{end}}' kind); do
  echo "Waiting for Docker network information..."
  sleep 5
done

NET_IP=$(echo ${GW_IP} | sed -E 's|^([0-9]+\.[0-9]+)\..*$|\1|g')

until cat <<EOF | sed -E "s|172.19|${NET_IP}|g" | kubectl apply -f -
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: ip-pool
  namespace: metallb-system
spec:
  addresses:
    - 172.19.255.200-172.19.255.250
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: l2adv
  namespace: metallb-system
EOF
do
  echo "Retrying MetalLB configuration in 5 seconds..."
  sleep 5
done

kubectl cluster-info
echo "Cluster setup complete!"
