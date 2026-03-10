#!/bin/bash
set -euo pipefail

# --- CONFIG ---
SSH_KEY="./ssh/k8s-cluster-from-ground-up.pem"
SSH_USER="ubuntu"
MASTER_IPS=("13.40.3.245" "3.10.58.110" "13.40.106.71")   # Public IPs for SSH
ETCD_PRIVATE_IPS=("172.31.0.10" "172.31.0.11" "172.31.0.12") # Etcd listens on private IPs
CERT_DIR="./k8s-pki"
K8S_VERSION="v1.21.0"
BIN_URL_BASE="https://storage.googleapis.com/kubernetes-release/release/${K8S_VERSION}/bin/linux/amd64"
CONTROL_PLANE_FILES=("kube-apiserver" "kube-controller-manager" "kube-scheduler" "kubectl")
MAX_HEALTH_CHECK_RETRIES=15
HEALTH_CHECK_INTERVAL=5

# --- FUNCTIONS ---
copy_files_to_master() {
    local ip=$1
    echo "[INFO][$ip] Preparing directories and copying PKI/kubeconfigs..."
    ssh -i "$SSH_KEY" "$SSH_USER@$ip" "
        sudo mkdir -p /var/lib/kubernetes /etc/kubernetes/config
        sudo chown $SSH_USER:$SSH_USER /var/lib/kubernetes
    "
    scp -i "$SSH_KEY" "$CERT_DIR"/*.pem "$SSH_USER@$ip:/tmp/"
    scp -i "$SSH_KEY" encryption-config.yaml "$SSH_USER@$ip:/tmp/"
    scp -i "$SSH_KEY" "$CERT_DIR/admin.kubeconfig" "$CERT_DIR/kube-controller-manager.kubeconfig" "$CERT_DIR/kube-scheduler.kubeconfig" "$SSH_USER@$ip:/tmp/"

    ssh -i "$SSH_KEY" "$SSH_USER@$ip" "
        sudo mv /tmp/*.pem /var/lib/kubernetes/
        sudo mv /tmp/encryption-config.yaml /var/lib/kubernetes/
        sudo mv /tmp/*.kubeconfig /var/lib/kubernetes/
        sudo chown root:root /var/lib/kubernetes/*
        sudo chmod 600 /var/lib/kubernetes/*.pem
        sudo chmod 644 /var/lib/kubernetes/*.kubeconfig
    "
    echo "[INFO][$ip] PKI and kubeconfigs copied and permissions set."
}

install_binaries() {
    local ip=$1
    echo "[INFO][$ip] Installing Kubernetes binaries..."
    ssh -i "$SSH_KEY" "$SSH_USER@$ip" "
        for bin in ${CONTROL_PLANE_FILES[@]}; do
            wget -q --https-only --timestamping ${BIN_URL_BASE}/\$bin
            chmod +x \$bin
            sudo mv \$bin /usr/local/bin/
        done
    "
}

check_api_health() {
    local ip=$1
    local retries=0
    echo "[INFO][$ip] Checking API server health..."
    until ssh -i "$SSH_KEY" "$SSH_USER@$ip" "kubectl --kubeconfig=/var/lib/kubernetes/admin.kubeconfig get componentstatuses" &>/dev/null; do
        retries=$((retries+1))
        if [ "$retries" -ge "$MAX_HEALTH_CHECK_RETRIES" ]; then
            echo "[ERROR][$ip] API server failed to become healthy after retries."
            return 1
        fi
        echo "[WARN][$ip] API server not ready yet, retrying in $HEALTH_CHECK_INTERVAL seconds..."
        sleep "$HEALTH_CHECK_INTERVAL"
    done
    echo "[INFO][$ip] API server is healthy."
}

# --- STEP 1: Copy PKI and kubeconfigs in parallel ---
echo "[INFO] Copying PKI and kubeconfigs to all master nodes..."
for ip in "${MASTER_IPS[@]}"; do
    copy_files_to_master "$ip" &
done
wait
echo "[INFO] All PKI and kubeconfigs copied."

# --- STEP 2: Install binaries in parallel ---
echo "[INFO] Installing Kubernetes binaries on all master nodes..."
for ip in "${MASTER_IPS[@]}"; do
    install_binaries "$ip" &
done
wait
echo "[INFO] Binaries installed."

# --- STEP 3: Deploy control plane systemd services ---
for idx in "${!MASTER_IPS[@]}"; do
    ip=${MASTER_IPS[$idx]}
    etcd_ip_list=$(IFS=,; echo "${ETCD_PRIVATE_IPS[*]/#/https://}" | sed 's/$/:2379/')
    echo "[INFO][$ip] Deploying control plane services..."
    ssh -i "$SSH_KEY" "$SSH_USER@$ip" bash -s <<EOF
INTERNAL_IP=\$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)
sudo mkdir -p /var/log
sudo touch /var/log/audit.log
sudo chown root:root /var/log/audit.log

cat <<EOL | sudo tee /etc/systemd/system/kube-apiserver.service
[Unit]
Description=Kubernetes API Server
Documentation=https://github.com/kubernetes/kubernetes
[Service]
ExecStart=/usr/local/bin/kube-apiserver \\
  --advertise-address=\${INTERNAL_IP} \\
  --allow-privileged=true \\
  --apiserver-count=3 \\
  --audit-log-maxage=30 \\
  --audit-log-maxbackup=3 \\
  --audit-log-maxsize=100 \\
  --audit-log-path=/var/log/audit.log \\
  --authorization-mode=Node,RBAC \\
  --bind-address=0.0.0.0 \\
  --client-ca-file=/var/lib/kubernetes/ca.pem \\
  --enable-admission-plugins=NamespaceLifecycle,NodeRestriction,LimitRanger,ServiceAccount,DefaultStorageClass,ResourceQuota \\
  --etcd-cafile=/var/lib/kubernetes/ca.pem \\
  --etcd-certfile=/var/lib/kubernetes/master-kubernetes.pem \\
  --etcd-keyfile=/var/lib/kubernetes/master-kubernetes-key.pem \\
  --etcd-servers=${etcd_ip_list} \\
  --event-ttl=1h \\
  --encryption-provider-config=/var/lib/kubernetes/encryption-config.yaml \\
  --kubelet-certificate-authority=/var/lib/kubernetes/ca.pem \\
  --kubelet-client-certificate=/var/lib/kubernetes/master-kubernetes.pem \\
  --kubelet-client-key=/var/lib/kubernetes/master-kubernetes-key.pem \\
  --runtime-config=api/all=true \\
  --service-account-key-file=/var/lib/kubernetes/service-account.pem \\
  --service-account-signing-key-file=/var/lib/kubernetes/service-account-key.pem \\
  --service-account-issuer=https://\${INTERNAL_IP}:6443 \\
  --service-cluster-ip-range=172.32.0.0/24 \\
  --service-node-port-range=30000-32767 \\
  --tls-cert-file=/var/lib/kubernetes/master-kubernetes.pem \\
  --tls-private-key-file=/var/lib/kubernetes/master-kubernetes-key.pem \\
  --v=2
Restart=on-failure
RestartSec=5
[Install]
WantedBy=multi-user.target
EOL

sudo systemctl daemon-reload
sudo systemctl enable kube-apiserver
sudo systemctl start kube-apiserver
EOF
done

# --- STEP 4: Wait and check API health ---
echo "[INFO] Verifying API server health on all master nodes..."
for ip in "${MASTER_IPS[@]}"; do
    check_api_health "$ip" &
done
wait

echo "[INFO] Kubernetes control plane bootstrap complete!"
echo "[INFO] Verify manually with: kubectl --kubeconfig=./k8s-pki/admin.kubeconfig get componentstatuses"