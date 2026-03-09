#!/bin/bash
set -euo pipefail

# --- CONFIG ---
SSH_KEY="./ssh/k8s-cluster-from-ground-up.pem"
SSH_USER="ubuntu"
# Replace these with the actual Public IPs of your Worker-0, Worker-1, and Worker-2
WORKER_IPS=("35.179.154.34" "35.177.215.83" "18.171.211.27") 

bootstrap_worker() {
    local worker_ip=$1
    echo "[INFO][$worker_ip] Starting bootstrap process..."

    ssh -i "$SSH_KEY" "$SSH_USER@$worker_ip" bash -s <<'EOF'
set -euo pipefail

echo ">>> 1. Installing OS Dependencies..."
sudo apt-get update
sudo apt-get -y install socat conntrack ipset

echo ">>> 2. Disabling Swap..."
sudo swapoff -a

echo ">>> 3. Downloading Containerd and runc..."
wget -q --show-progress --https-only --timestamping \
  https://github.com/opencontainers/runc/releases/download/v1.0.0-rc93/runc.amd64 \
  https://github.com/kubernetes-sigs/cri-tools/releases/download/v1.21.0/crictl-v1.21.0-linux-amd64.tar.gz \
  https://github.com/containerd/containerd/releases/download/v1.4.4/containerd-1.4.4-linux-amd64.tar.gz

echo ">>> 4. Configuring Containerd..."
mkdir -p containerd
tar -xvf crictl-v1.21.0-linux-amd64.tar.gz
tar -xvf containerd-1.4.4-linux-amd64.tar.gz -C containerd
sudo mv runc.amd64 runc
chmod +x crictl runc
sudo mv crictl runc /usr/local/bin/
sudo mv containerd/bin/* /bin/

sudo mkdir -p /etc/containerd/
cat <<TOML | sudo tee /etc/containerd/config.toml
[plugins]
  [plugins.cri.containerd]
    snapshotter = "overlayfs"
    [plugins.cri.containerd.default_runtime]
      runtime_type = "io.containerd.runtime.v1.linux"
      runtime_engine = "/usr/local/bin/runc"
      runtime_root = ""
TOML

cat <<SRV | sudo tee /etc/systemd/system/containerd.service
[Unit]
Description=containerd container runtime
Documentation=https://containerd.io
After=network.target

[Service]
ExecStartPre=/sbin/modprobe overlay
ExecStart=/bin/containerd
Restart=always
RestartSec=5
Delegate=yes
KillMode=process
OOMScoreAdjust=-999
LimitNOFILE=1048576
LimitNPROC=infinity
LimitCORE=infinity

[Install]
WantedBy=multi-user.target
SRV

echo ">>> 5. Creating Kubelet and CNI directories..."
sudo mkdir -p \
  /var/lib/kubelet \
  /var/lib/kube-proxy \
  /etc/cni/net.d \
  /opt/cni/bin \
  /var/lib/kubernetes \
  /var/run/kubernetes

echo ">>> 6. Downloading and Installing CNI plugins..."
wget -q --show-progress --https-only --timestamping \
  https://github.com/containernetworking/plugins/releases/download/v0.9.1/cni-plugins-linux-amd64-v0.9.1.tgz
sudo tar -xvf cni-plugins-linux-amd64-v0.9.1.tgz -C /opt/cni/bin/

echo ">>> 7. Downloading and Installing Kubernetes Binaries (v1.21.0)..."
wget -q --show-progress --https-only --timestamping \
  https://storage.googleapis.com/kubernetes-release/release/v1.21.0/bin/linux/amd64/kubectl \
  https://storage.googleapis.com/kubernetes-release/release/v1.21.0/bin/linux/amd64/kube-proxy \
  https://storage.googleapis.com/kubernetes-release/release/v1.21.0/bin/linux/amd64/kubelet

chmod +x kubectl kube-proxy kubelet
sudo mv kubectl kube-proxy kubelet /usr/local/bin/

echo ">>> Starting containerd service..."
sudo systemctl daemon-reload
sudo systemctl enable containerd
sudo systemctl start containerd

echo ">>> [$worker_ip] Base bootstrap complete!"
EOF
}

# --- RUN ON ALL WORKER NODES CONCURRENTLY ---
for ip in "${WORKER_IPS[@]}"; do
    bootstrap_worker "$ip" &
done
wait

echo "[INFO] All worker nodes have been successfully bootstrapped with binaries and container runtimes!"
