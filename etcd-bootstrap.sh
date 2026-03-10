#!/bin/bash
set -euo pipefail

# --- CONFIG ---
SSH_KEY="./ssh/k8s-cluster-from-ground-up.pem"
SSH_USER="ubuntu"
MASTER_IPS=("13.40.3.245" "3.10.58.110" "13.40.106.71")   # Public IPs for SSH
ETCD_PRIVATE_IPS=("172.31.0.10" "172.31.0.11" "172.31.0.12") # Etcd listens on private IPs
PKI_DIR="./k8s-pki"
ETCD_BIN="/usr/local/bin/etcd"
ETCDCTL_BIN="/usr/local/bin/etcdctl"

# --- FUNCTIONS ---
copy_certs_and_binaries() {
    local ip=$1
    echo "[INFO][$ip] Copying certificates and etcd binaries..."
    scp -i "$SSH_KEY" "$PKI_DIR"/*.pem "$SSH_USER@$ip:/tmp/"
    scp -i "$SSH_KEY" "$ETCD_BIN" "$ETCDCTL_BIN" "$SSH_USER@$ip:/tmp/"
    ssh -i "$SSH_KEY" "$SSH_USER@$ip" bash -s <<EOF
sudo mkdir -p /etc/etcd /var/lib/etcd
sudo mv /tmp/*.pem /etc/etcd/
sudo mv /tmp/etcd /usr/local/bin/
sudo mv /tmp/etcdctl /usr/local/bin/
sudo chmod 600 /etc/etcd/*.pem
sudo chmod +x /usr/local/bin/etcd /usr/local/bin/etcdctl
EOF
}

setup_etcd_service() {
    local idx=$1
    local ip=${MASTER_IPS[$idx]}
    local private_ip=${ETCD_PRIVATE_IPS[$idx]}
    local etcd_cluster=""
    for i in "${!MASTER_IPS[@]}"; do
        etcd_cluster+="master$((i+1))=https://${ETCD_PRIVATE_IPS[$i]}:2380,"
    done
    etcd_cluster=${etcd_cluster%,}  # remove trailing comma

    echo "[INFO][$ip] Setting up ETCD systemd service..."
    ssh -i "$SSH_KEY" "$SSH_USER@$ip" bash -s <<EOF
sudo tee /etc/systemd/system/etcd.service > /dev/null <<EOL
[Unit]
Description=etcd
Documentation=https://etcd.io
After=network.target

[Service]
ExecStart=/usr/local/bin/etcd \\
  --name master$((idx+1)) \\
  --data-dir /var/lib/etcd \\
  --initial-advertise-peer-urls https://${private_ip}:2380 \\
  --listen-peer-urls https://${private_ip}:2380 \\
  --listen-client-urls=https://${private_ip}:2379,https://127.0.0.1:2379 \\
  --advertise-client-urls=https://${private_ip}:2379 \\
  --initial-cluster=${etcd_cluster} \\
  --initial-cluster-state new \\
  --cert-file=/etc/etcd/master-kubernetes.pem \\
  --key-file=/etc/etcd/master-kubernetes-key.pem \\
  --peer-cert-file=/etc/etcd/master-kubernetes.pem \\
  --peer-key-file=/etc/etcd/master-kubernetes-key.pem \\
  --trusted-ca-file=/etc/etcd/ca.pem \\
  --peer-trusted-ca-file=/etc/etcd/ca.pem \\
  --peer-client-cert-auth \\
  --client-cert-auth
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOL

sudo systemctl daemon-reload
sudo systemctl enable etcd
sudo systemctl start etcd
EOF
}

check_etcd_health() {
    local ip=$1
    echo "[INFO][$ip] Checking ETCD health..."
    ssh -i "$SSH_KEY" "$SSH_USER@$ip" bash -s <<EOF
sudo ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 --cacert=/etc/etcd/ca.pem --cert=/etc/etcd/master-kubernetes.pem --key=/etc/etcd/master-kubernetes-key.pem endpoint health
EOF
}

# --- MAIN SCRIPT ---
echo "[INFO] Bootstrapping ETCD cluster from local machine..."

# Step 1: Copy certificates and binaries
for ip in "${MASTER_IPS[@]}"; do
    copy_certs_and_binaries "$ip" &
done
wait
echo "[INFO] Certificates and binaries copied to all masters."

# Step 2: Setup ETCD service
for idx in "${!MASTER_IPS[@]}"; do
    setup_etcd_service "$idx" &
done
wait
echo "[INFO] ETCD systemd services configured and started."

# Step 3: Check ETCD health
for ip in "${MASTER_IPS[@]}"; do
    check_etcd_health "$ip" &
done
wait
echo "[INFO] ETCD cluster bootstrapped successfully!"