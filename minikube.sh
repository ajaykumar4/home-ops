#!/usr/bin/env bash
set -euo pipefail

# Configuration Variables
KUBERNETES_VERSION="v1.35.8"
SERVICE_CIDR="10.43.0.0/16"
POD_CIDR="10.244.0.0/16"

echo "=== Step 1: Cleaning up existing Minikube cluster ==="
minikube delete || true

echo "=== Step 2: Provisioning Minikube Cluster with Custom CIDRs ==="
minikube start \
  --driver=podman \
  --container-runtime=docker \
  --cpus=8 \
  --memory=24576mb \
  --disk-size=80g \
  --kubernetes-version="${KUBERNETES_VERSION}" \
  --cni=false \
  --embed-certs \
  --service-cluster-ip-range="${SERVICE_CIDR}" \
  --extra-config=kubeadm.pod-network-cidr="${POD_CIDR}"

echo "=== Step 3: Removing Default CoreDNS Resources ==="
kubectl delete deployment coredns -n kube-system --ignore-not-found
kubectl delete service kube-dns -n kube-system --ignore-not-found
kubectl delete serviceaccount coredns -n kube-system --ignore-not-found
kubectl delete configmap coredns -n kube-system --ignore-not-found
