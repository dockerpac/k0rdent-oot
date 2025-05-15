# Pre-requisites

- Install ProviderTemplate `cluster-api-provider-kubevirt-0-3-0` from https://github.com/dockerpac/kubevirt-oot
- Helm charts in `<custom registry>/k0rdent-enterprise` :
  - oci://ghcr.io/dockerpac/k0rdent-oot/kubevirt-standalone-cp --version 0.3.1
- Images in `<custom registry>/k0rdent-enterprise` :
  - ghcr.io/k0rdent-oot/kubevirt-container-disk:debian-latest (optional)
  - quay.io/kubevirt/kubevirt-cloud-controller-manager:v0.5.1
- k0s binary available at `<custom http server>/`
  - https://github.com/k0sproject/k0s/releases/download/v1.31.5+k0s.0/k0s-v1.31.5+k0s.0-amd64


## Install ClusterTemplate (airgap)

```sh
kubectl apply -f - <<EOF
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: k0rdent-oot
  namespace: kcm-system
  labels:
    k0rdent.mirantis.com/managed: "true"
spec:
  type: oci
  url: oci://ghcr.io/dockerpac/k0rdent-oot
  interval: 10m0s
---
apiVersion: k0rdent.mirantis.com/v1alpha1
kind: ClusterTemplate
metadata:
  name: kubevirt-standalone-cp-0-3-1
  namespace: kcm-system
  annotations:
    helm.sh/resource-policy: keep
spec:
  helm:
    chartSpec:
      chart: kubevirt-standalone-cp
      version: 0.3.1
      interval: 10m0s
      sourceRef:
        kind: HelmRepository
        name: k0rdent-oot
EOF
```

## Prepare Child cluster deployment

```sh
kubectl apply -f - <<EOF
---
apiVersion: v1
kind: Secret
metadata:
  name: kubevirt-config
  namespace: kcm-system
  labels:
    k0rdent.mirantis.com/component: "kcm"
---
apiVersion: k0rdent.mirantis.com/v1alpha1
kind: Credential
metadata:
  name: kubevirt-cluster-identity-cred
  namespace: kcm-system
spec:
  description: KubeVirt credentials
  identityRef:
    apiVersion: v1
    kind: Secret
    name: kubevirt-config
    namespace: kcm-system
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: kubevirt-config-resource-template
  namespace: kcm-system
  labels:
    k0rdent.mirantis.com/component: "kcm"
  annotations:
    projectsveltos.io/template: "true"
EOF
```

## Create a simple child cluster

```sh
kubectl apply -f - <<EOF
---
apiVersion: k0rdent.mirantis.com/v1alpha1
kind: ClusterDeployment
metadata:
  name: kubevirt-demo
  namespace: kcm-system
spec:
  template: kubevirt-standalone-cp-0-3-1
  credential: kubevirt-cluster-identity-cred
  config:
    k0s:
      version: v1.31.5+k0s.0
    singleArtifactSource:
      enabled: true
      registry: registry.mirantis.com/k0rdent-enterprise
      k0sURL: https://github.com/k0sproject/k0s/releases/download/v1.31.5+k0s.0
    controlPlaneNumber: 1
    workersNumber: 1
    controlPlane:
      image: ghcr.io/k0rdent-oot/kubevirt-container-disk:debian-latest
      preStartCommands:
        - passwd -u root
        - echo "root:root" | chpasswd
    worker:
      image: ghcr.io/k0rdent-oot/kubevirt-container-disk:debian-latest
      preStartCommands:
        - passwd -u root
        - echo "root:root" | chpasswd
    cloudControllerManager:
      repo: quay.io/kubevirt
EOF
```

## Create a complex child cluster

### Multus NetworkAttachmentDefinition

```sh
kubectl apply -f - <<EOF
---
apiVersion: "k8s.cni.cncf.io/v1"
kind: NetworkAttachmentDefinition
metadata:
  name: bridge-1560
  namespace: kcm-system
spec:
  config: '{
        "cniVersion": "0.3.1",
        "name": "bridge-1560",
          "plugins": [
           {
             "type": "bridge",
             "bridge": "br1560"
           },
           {
             "type": "tuning"
           }
          ]
        }'
EOF
```

### CDI DataVolume

```sh
kubectl apply -f - <<EOF
---
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: ubuntu2204
  namespace: kcm-system
  annotations:
    # https://github.com/kubevirt/containerized-data-importer/blob/main/doc/waitforfirstconsumer-storage-handling.md
    cdi.kubevirt.io/storage.bind.immediate.requested: ""
spec:
  source:
    http:
      url: "https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"
  pvc:
    accessModes:
      - ReadWriteMany
    volumeMode: Block
    resources:
      requests:
        storage: 50Gi
EOF
```

### Create a "Golden image" with a Volume Snapshot

```sh
kubectl apply -f - <<EOF
---
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: goldenimage-ubuntu2204
  namespace: kcm-system
spec:
  #volumeSnapshotClassName: csi-ceph-blockpool
  volumeSnapshotClassName: csi-rbdplugin-snapclass
  source:
    persistentVolumeClaimName: ubuntu2204
EOF
```

### ClusterDeployment

Features implemented in this CLD : 
- airgap
- configuring pod and service cidr
- 3 cp + 3 workers
- Configuring cpu/mem for cp and workers
- KCCM multiple replicas + topologySpreadConstraints across zones
- Cluster labels
- attachement to additional network using Multus
- Using VolumeSnapshot as root disk for fast init and persistence + additional data disk on worker nodes
- qemu-guest-agent installation
- MachineHealthCheck with 60% maxUnhealthy
- Dedicated VXLAN port for Calico

```sh
kubectl apply -f - <<EOF
---
apiVersion: k0rdent.mirantis.com/v1alpha1
kind: ClusterDeployment
metadata:
  name: kubevirt-demo
  namespace: kcm-system
spec:
  template: kubevirt-standalone-cp-0-3-1
  credential: kubevirt-cluster-identity-cred
  config:
    clusterLabels:
      project: demo
      env: dev
    clusterNetwork:
      pods:
        cidrBlocks:
          - "10.249.0.0/16"
      services:
        cidrBlocks:
          - "10.250.0.0/16"
    controlPlaneNumber: 3
    workersNumber: 3
    controlPlane:
      cpus: 2
      memory: "4Gi"
      dataVolumes:
        - name: root
          accessModes: ReadWriteMany
          storage: 50Gi
          volumeMode: Block
          storageClassName: block-pool
          source:
            snapshot:
              namespace: kcm-system
              name: goldenimage-ubuntu2204
      bootstrapCheckStrategy: none
      runStrategy: Once
      preStartCommands:
      #  - apt update
      #  - env DEBIAN_FRONTEND=noninteractive apt -y install qemu-guest-agent
      #  - systemctl enable --now qemu-guest-agent
        - passwd -u root
        - echo "root:root" | chpasswd
      additionalNetworkInterfaces:
        - name: bridge-net
          multus:
            networkName: bridge-1560
    worker:
      cpus: 2
      memory: "4Gi"
      dataVolumes:
        - name: root
          accessModes: ReadWriteMany
          storage: 50Gi
          volumeMode: Block
          storageClassName: block-pool
          source:
            snapshot:
              namespace: kcm-system
              name: goldenimage-ubuntu2204
        - name: data
          accessModes: ReadWriteMany
          storage: 1Gi
          volumeMode: Block
          storageClassName: block-pool
          source:
            blank: {}
      bootstrapCheckStrategy: none
      runStrategy: Once
      preStartCommands:
      #  - apt update
      #  - env DEBIAN_FRONTEND=noninteractive apt -y install qemu-guest-agent
      #  - systemctl enable --now qemu-guest-agent
        - passwd -u root
        - echo "root:root" | chpasswd
      additionalNetworkInterfaces:
        - name: bridge-net
          multus:
            networkName: bridge-1560
    k0s:
      version: v1.31.5+k0s.0
      api:
        extraArgs: {}
      network:
        vxlanPort: 5789
    machineHealthCheck:
      enabled: true
      maxUnhealthy: 60%
    cloudControllerManager:
      replicas: 3
      repo: quay.io/kubevirt
      topologySpreadConstraints:
        - labelSelector:
            matchLabels:
              k8s-app: kubevirt-cloud-controller-manager-{{ .Release.Name }}
          matchLabelKeys:
          - pod-template-hash
          topologyKey: topology.kubernetes.io/zone
          maxSkew: 1
          whenUnsatisfiable: DoNotSchedule
    singleArtifactSource:
      enabled: true
      registry: registry.mirantis.com/k0rdent-enterprise
      k0sURL: https://github.com/k0sproject/k0s/releases/download/v1.31.5+k0s.0
EOF
```
