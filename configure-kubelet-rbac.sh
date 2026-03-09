#!/bin/bash
set -euo pipefail

# --- CONFIG ---
SSH_KEY="./ssh/k8s-cluster-from-ground-up.pem"
SSH_USER="ubuntu"
MASTER_IP="13.40.3.245"  # You only need one control plane IP to apply cluster state
KUBECONFIG_PATH="/var/lib/kubernetes/admin.kubeconfig"
LOCAL_API_SERVER="https://127.0.0.1:6443"

echo "[INFO] Applying Kubelet RBAC configuration to the cluster via $MASTER_IP..."

ssh -i "$SSH_KEY" "$SSH_USER@$MASTER_IP" bash -s <<EOF
cat <<YAML | kubectl --kubeconfig=$KUBECONFIG_PATH --server=$LOCAL_API_SERVER apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  annotations:
    rbac.authorization.kubernetes.io/autoupdate: "true"
  labels:
    kubernetes.io/bootstrapping: rbac-defaults
  name: system:kube-apiserver-to-kubelet
rules:
- apiGroups: [""]
  resources:
  - nodes/proxy
  - nodes/stats
  - nodes/log
  - nodes/spec
  - nodes/metrics
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: system:kube-apiserver
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:kube-apiserver-to-kubelet
subjects:
- apiGroup: rbac.authorization.k8s.io
  kind: User
  name: kubernetes
YAML

# --- VERIFY ---
echo "[INFO] Verifying Kubelet RBAC..."
kubectl --kubeconfig=$KUBECONFIG_PATH --server=$LOCAL_API_SERVER get nodes >/dev/null 2>&1
if [ \$? -eq 0 ]; then
    echo "[INFO] RBAC successfully applied to the cluster."
else
    echo "[ERROR] API server cannot communicate. Check RBAC and network."
fi
EOF

echo "[INFO] RBAC configuration for Kubelet authorization completed."
