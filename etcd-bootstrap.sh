#!/bin/bash

set -e

echo "===== REMOTE ETCD BOOTSTRAP STARTING ====="

SSH_KEY="./ssh/k8s-cluster-from-ground-up.pem"
SSH_USER="ubuntu"

PKI_DIR="./k8s-pki"
ETCD_VERSION="v3.5.9"

MASTERS=(
"13.40.3.245"
"3.10.58.110"
"13.40.106.71"
)

MASTER_NAMES=(
"master1"
"master2"
"master3"
)

INITIAL_CLUSTER="master1=https://13.40.3.245:2380,master2=https://3.10.58.110:2380,master3=https://13.40.106.71:2380"

echo "Checking PKI directory..."

if [ ! -d "$PKI_DIR" ]; then
  echo "PKI directory missing"
  exit 1
fi

for i in "${!MASTERS[@]}"
do

NODE_IP=${MASTERS[$i]}
NODE_NAME=${MASTER_NAMES[$i]}

echo ""
echo "Bootstrapping $NODE_NAME ($NODE_IP)"
echo ""

ssh -i $SSH_KEY $SSH_USER@$NODE_IP <<EOF

set -e

echo "Creating directories..."

sudo mkdir -p /etc/etcd
sudo mkdir -p /var/lib/etcd

echo "Installing etcd..."

if ! command -v etcd &> /dev/null
then

wget -q https://github.com/etcd-io/etcd/releases/download/${ETCD_VERSION}/etcd-${ETCD_VERSION}-linux-amd64.tar.gz

tar -xvf etcd-${ETCD_VERSION}-linux-amd64.tar.gz

sudo mv etcd-${ETCD_VERSION}-linux-amd64/etcd* /usr/local/bin/

rm -rf etcd-${ETCD_VERSION}-linux-amd64*

fi

echo "Creating etcd systemd service..."

sudo tee /etc/systemd/system/etcd.service > /dev/null <<SERVICE

[Unit]
Description=etcd
Documentation=https://etcd.io
After=network.target

[Service]

ExecStart=/usr/local/bin/etcd \\
--name ${NODE_NAME} \\
--data-dir /var/lib/etcd \\
--initial-advertise-peer-urls https://${NODE_IP}:2380 \\
--listen-peer-urls https://${NODE_IP}:2380 \\
--listen-client-urls https://${NODE_IP}:2379,https://127.0.0.1:2379 \\
--advertise-client-urls https://${NODE_IP}:2379 \\
--initial-cluster ${INITIAL_CLUSTER} \\
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

SERVICE

echo "Reloading systemd..."

sudo systemctl daemon-reload
sudo systemctl enable etcd
sudo systemctl restart etcd

EOF


echo "Copying certificates to $NODE_IP"

scp -i $SSH_KEY $PKI_DIR/* $SSH_USER@$NODE_IP:/tmp/

ssh -i $SSH_KEY $SSH_USER@$NODE_IP <<EOF

sudo mv /tmp/*.pem /etc/etcd/

EOF

done

echo ""
echo "===== ETCD BOOTSTRAP COMPLETE ====="
echo ""
