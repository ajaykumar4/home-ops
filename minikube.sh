#!/usr/bin/env bash
set -euo pipefail

# Configuration Variables
KUBERNETES_VERSION="v1.35.8"
SERVICE_CIDR="10.43.0.0/16"
POD_CIDR="10.244.0.0/16"
ZSCALER_CERT="${HOME}/.minikube/certs/zscaler-ca-bundle.pem"

echo "=== Step 1: Cleaning up existing Minikube cluster ==="
minikube delete || true

echo "=== Step 2: Provisioning Minikube Cluster with Custom CIDRs & Zscaler CA ==="
if [ ! -f "${ZSCALER_CERT}" ]; then
  echo "Error: Zscaler CA bundle not found at ${ZSCALER_CERT}"
  exit 1
fi

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
  --extra-config=kubeadm.pod-network-cidr="${POD_CIDR}" \
  --mount \
  --mount-string="${ZSCALER_CERT}:/etc/ssl/certs/zscaler-ca-bundle.pem"

echo "=== Step 3: Injecting Zscaler Certificate into Minikube Node Trust Store ==="
minikube ssh "sudo cp /etc/ssl/certs/zscaler-ca-bundle.pem /usr/local/share/ca-certificates/zscaler.crt && sudo update-ca-certificates"

echo "=== Step 4: Removing Default CoreDNS Resources ==="
kubectl delete deployment coredns -n kube-system --ignore-not-found
kubectl delete service kube-dns -n kube-system --ignore-not-found
kubectl delete serviceaccount coredns -n kube-system --ignore-not-found
kubectl delete configmap coredns -n kube-system --ignore-not-found

echo "=== Step 5: Bootstrapping Applications (Namespaces, Cilium, CoreDNS, ArgoCD) ==="
just bootstrap apps

echo "=== Step 6: Injecting Zscaler CA ConfigMap into argo-system ==="
kubectl create configmap zscaler-ca-cert \
  --from-file=ca-certificates.crt="${ZSCALER_CERT}" \
  -n argo-system --dry-run=client -o yaml | kubectl apply -f -

echo "=== Step 7: Applying Cilium Network Policy for ArgoCD Repo Server ==="
kubectl apply -f - <<EOF
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: argocd-repo-server-policy
  namespace: argo-system
spec:
  endpointSelector:
    matchLabels:
      app.kubernetes.io/name: argocd-repo-server
  ingress:
    - fromEndpoints:
        - matchLabels:
            app.kubernetes.io/part-of: argocd
      toPorts:
        - ports:
            - port: "8081"
              protocol: TCP
    - fromEntities:
        - host
        - remote-node
        - health
      toPorts:
        - ports:
            - port: "8081"
              protocol: TCP
  egress:
    - toEndpoints:
        - matchLabels:
            app.kubernetes.io/name: argocd-redis
      toPorts:
        - ports:
            - port: "6379"
              protocol: TCP
    - toEndpoints:
        - matchLabels:
            "k8s:io.kubernetes.pod.namespace": kube-system
            "k8s:k8s-app": kube-dns
      toPorts:
        - ports:
            - port: "53"
              protocol: UDP
            - port: "53"
              protocol: TCP
    - toEntities:
        - world
      toPorts:
        - ports:
            - port: "443"
              protocol: TCP
EOF

echo "=== Step 8: Restarting ArgoCD Repo Server to pick up Mounted CA Certificate ==="
kubectl rollout restart deployment argocd-repo-server -n argo-system

echo "=== Setup complete! ==="