#!/bin/bash
set -euo pipefail

# --- CONFIG ---
SSH_KEY="./ssh/k8s-cluster-from-ground-up.pem"
SSH_USER="ubuntu"

# Array format: "IP_ADDRESS WORKER_NAME POD_CIDR"
WORKERS=(
    "35.179.154.34 k8s-cluster-from-ground-up-worker-0 10.200.0.0/24"
    "35.177.215.83 k8s-cluster-from-ground-up-worker-1 10.200.1.0/24"
    "18.171.211.27 k8s-cluster-from-ground-up-worker-2 10.200.2.0/24"
)

configure_worker() {
    local worker_ip=$1
    local worker_name=$2
    local pod_cidr=$3
    
    echo "[INFO][$worker_ip] Starting configuration for $worker_name..."

    # Pass the variables into the SSH session as arguments ($1 and $2)
    ssh -i "$SSH_KEY" "$SSH_USER@$worker_ip" bash -s "$worker_name" "$pod_cidr" <<'EOF'
set -euo pipefail

WORKER_NAME=$1
POD_CIDR=$2

echo "    Worker Name: ${WORKER_NAME}"
echo "    Pod CIDR:    ${POD_CIDR}"

echo ">>> 10. Configuring Bridge and Loopback networks..."
cat <<CNI | sudo tee /etc/cni/net.d/172-20-bridge.conf >/dev/null
{
    "cniVersion": "0.3.1",
    "name": "bridge",
    "type": "bridge",
    "bridge": "cnio0",
    "isGateway": true,
    "ipMasq": true,
    "ipam": {
        "type": "host-local",
        "ranges": [
          [{"subnet": "${POD_CIDR}"}]
        ],
        "routes": [{"dst": "0.0.0.0/0"}]
    }
}
CNI

cat <<CNI | sudo tee /etc/cni/net.d/99-loopback.conf >/dev/null
{
    "cniVersion": "0.3.1",
    "type": "loopback"
}
CNI

echo ">>> 13. Moving Certificates and Kubeconfigs..."
sudo mv /home/ubuntu/${WORKER_NAME}-key.pem /var/lib/kubelet/ || true
sudo mv /home/ubuntu/${WORKER_NAME}.pem /var/lib/kubelet/ || true
sudo mv /home/ubuntu/${WORKER_NAME}.kubeconfig /var/lib/kubelet/kubeconfig || true
sudo mv /home/ubuntu/kube-proxy.kubeconfig /var/lib/kube-proxy/kubeconfig || true
sudo mv /home/ubuntu/ca.pem /var/lib/kubernetes/ || true

echo ">>> 14. Creating Kubelet Configuration..."
cat <<YAML | sudo tee /var/lib/kubelet/kubelet-config.yaml >/dev/null
kind: KubeletConfiguration
apiVersion: kubelet.config.k8s.io/v1beta1
authentication:
  anonymous:
    enabled: false
  webhook:
    enabled: true
  x509:
    clientCAFile: "/var/lib/kubernetes/ca.pem"
authorization:
  mode: Webhook
clusterDomain: "cluster.local"
clusterDNS:
  - "10.32.0.10"
resolvConf: "/etc/resolv.conf"
runtimeRequestTimeout: "15m"
tlsCertFile: "/var/lib/kubelet/${WORKER_NAME}.pem"
tlsPrivateKeyFile: "/var/lib/kubelet/${WORKER_NAME}-key.pem"
YAML

echo ">>> 15. Configuring Kubelet Systemd Service..."
cat <<SRV | sudo tee /etc/systemd/system/kubelet.service >/dev/null
[Unit]
Description=Kubernetes Kubelet
Documentation=https://github.com/kubernetes/kubernetes
After=containerd.service
Requires=containerd.service

[Service]
ExecStart=/usr/local/bin/kubelet \
  --config=/var/lib/kubelet/kubelet-config.yaml \
  --container-runtime=remote \
  --container-runtime-endpoint=unix:///var/run/containerd/containerd.sock \
  --image-pull-progress-deadline=2m \
  --kubeconfig=/var/lib/kubelet/kubeconfig \
  --network-plugin=cni \
  --register-node=true \
  --v=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
SRV

echo ">>> 16. Creating Kube-Proxy Configuration..."
cat <<YAML | sudo tee /var/lib/kube-proxy/kube-proxy-config.yaml >/dev/null
kind: KubeProxyConfiguration
apiVersion: kubeproxy.config.k8s.io/v1alpha1
clientConnection:
  kubeconfig: "/var/lib/kube-proxy/kubeconfig"
mode: "iptables"
clusterCIDR: "10.200.0.0/16"
YAML

echo ">>> 17. Configuring Kube-Proxy Systemd Service..."
cat <<SRV | sudo tee /etc/systemd/system/kube-proxy.service >/dev/null
[Unit]
Description=Kubernetes Kube Proxy
Documentation=https://github.com/kubernetes/kubernetes

[Service]
ExecStart=/usr/local/bin/kube-proxy \
  --config=/var/lib/kube-proxy/kube-proxy-config.yaml
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
SRV

echo ">>> 18. Starting Kubelet and Kube-Proxy..."
sudo systemctl daemon-reload
sudo systemctl enable containerd kubelet kube-proxy
sudo systemctl restart containerd kubelet kube-proxy

echo ">>> [$WORKER_NAME] Configuration complete!"
EOF
}

# --- RUN ON ALL WORKER NODES CONCURRENTLY ---
for worker in "${WORKERS[@]}"; do
    # Read the space-separated string into variables
    read -r ip name cidr <<< "$worker"
    configure_worker "$ip" "$name" "$cidr" &
done
wait

echo "[INFO] All worker nodes have been configured and joined to the cluster!"
