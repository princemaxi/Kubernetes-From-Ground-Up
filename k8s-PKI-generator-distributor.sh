#!/bin/bash
#====================================================
# Kubernetes PKI Generator & Distributor (End-to-End)
# Fully Automated, Idempotent, SCP with Retries
#====================================================

set -euo pipefail

#-------------------------
# CONFIGURATION
#-------------------------
NAME="k8s-cluster-from-ground-up"
REGION="eu-west-2"
PKI_DIR="$HOME/k8s-pki"
SSH_KEY="$PWD/ssh/$NAME.pem"
SSH_USER="ubuntu"   # Ubuntu AMI

mkdir -p "$PKI_DIR"
cd "$PKI_DIR"

export AWS_DEFAULT_REGION=$REGION

#-------------------------
# Fetch Kubernetes Public Address (NLB)
#-------------------------
echo "[INFO] Fetching Kubernetes NLB public DNS..."
KUBERNETES_PUBLIC_ADDRESS=$(aws elbv2 describe-load-balancers \
    --names "$NAME" \
    --query 'LoadBalancers[0].DNSName' \
    --output text)

if [[ -z "$KUBERNETES_PUBLIC_ADDRESS" ]]; then
    echo "[ERROR] Could not fetch NLB DNS name."
    exit 1
fi
echo "[INFO] Kubernetes Public Address: $KUBERNETES_PUBLIC_ADDRESS"

#-------------------------
# Fetch Master and Worker Private IPs
#-------------------------
echo "[INFO] Fetching Master and Worker IPs..."
MASTERS=()
WORKERS=()

for i in 0 1 2; do
    MASTER_IP=$(aws ec2 describe-instances \
        --region $REGION \
        --filters "Name=tag:Name,Values=${NAME}-master-$i" "Name=instance-state-name,Values=running" \
        --query "Reservations[0].Instances[0].PrivateIpAddress" --output text)
    MASTERS+=("$MASTER_IP")

    WORKER_IP=$(aws ec2 describe-instances \
        --region $REGION \
        --filters "Name=tag:Name,Values=${NAME}-worker-$i" "Name=instance-state-name,Values=running" \
        --query "Reservations[0].Instances[0].PrivateIpAddress" --output text)
    WORKERS+=("$WORKER_IP")
done

echo "[INFO] Masters: ${MASTERS[@]}"
echo "[INFO] Workers: ${WORKERS[@]}"

#-------------------------
# Step 1: Create CA if not exists
#-------------------------
if [[ ! -f ca.pem || ! -f ca-key.pem ]]; then
  echo "[INFO] Creating CA..."
  cat > ca-config.json <<EOF
{
  "signing": {
    "default": { "expiry": "8760h" },
    "profiles": { "kubernetes": { "usages": ["signing","key encipherment","server auth","client auth"], "expiry": "8760h" } }
  }
}
EOF

  cat > ca-csr.json <<EOF
{
  "CN": "Kubernetes",
  "key": { "algo": "rsa", "size": 2048 },
  "names": [ { "C":"UK","L":"London","O":"Kubernetes","OU":"StegHub.com DEVOPS","ST":"England"} ]
}
EOF

  cfssl gencert -initca ca-csr.json | cfssljson -bare ca
else
  echo "[INFO] CA already exists. Skipping."
fi

#-------------------------
# Step 2: API Server Certificate
#-------------------------
API_CERT="master-kubernetes.pem"
if [[ ! -f $API_CERT ]]; then
  echo "[INFO] Generating API server certificate..."
  API_HOSTS=("127.0.0.1" "${MASTERS[@]}" "$KUBERNETES_PUBLIC_ADDRESS" \
  "kubernetes" "kubernetes.default" "kubernetes.default.svc" \
  "kubernetes.default.svc.cluster" "kubernetes.default.svc.cluster.local")

  cat > master-kubernetes-csr.json <<EOF
{
  "CN": "kubernetes",
  "hosts": [$(printf '"%s",' "${API_HOSTS[@]}" | sed 's/,$//')],
  "key": { "algo":"rsa","size":2048 },
  "names": [ { "C":"UK","L":"London","O":"Kubernetes","OU":"StegHub.com DEVOPS","ST":"England"} ]
}
EOF

  cfssl gencert -ca=ca.pem -ca-key=ca-key.pem -config=ca-config.json -profile=kubernetes \
    master-kubernetes-csr.json | cfssljson -bare master-kubernetes
else
  echo "[INFO] API server certificate already exists. Skipping."
fi

#-------------------------
# Step 3: Client Certificates Function
#-------------------------
generate_client_cert() {
  local NAME="$1"
  local CN="$2"
  local O="$3"
  if [[ -f "${NAME}.pem" ]]; then
    echo "[INFO] Client certificate $NAME already exists. Skipping."
    return
  fi
  cat > ${NAME}-csr.json <<EOF
{
  "CN": "${CN}",
  "key": { "algo":"rsa","size":2048 },
  "names": [ { "C":"UK","L":"London","O":"${O}","OU":"StegHub.com DEVOPS","ST":"England"} ]
}
EOF
  cfssl gencert -ca=ca.pem -ca-key=ca-key.pem -config=ca-config.json -profile=kubernetes ${NAME}-csr.json | cfssljson -bare ${NAME}
  echo "[INFO] Generated client certificate: ${NAME}"
}

generate_client_cert "kube-scheduler" "system:kube-scheduler" "system:kube-scheduler"
generate_client_cert "kube-controller-manager" "system:kube-controller-manager" "system:kube-controller-manager"
generate_client_cert "kube-proxy" "system:node-proxier" "system:nodes"
generate_client_cert "admin" "admin" "system:masters"
generate_client_cert "service-account" "service-accounts" "Kubernetes"

#-------------------------
# Step 4: Kubelet Worker Certificates (use instance names as filenames)
#-------------------------
for i in 0 1 2; do
  WORKER_NAME="${NAME}-worker-$i"
  HOSTNAME="${WORKERS[$i]}"    # private IP
  PUBLIC_IP=$(aws ec2 describe-instances --region $REGION --filters "Name=tag:Name,Values=${WORKER_NAME}" --query "Reservations[0].Instances[0].PublicIpAddress" --output text)

  if [[ ! -f "${WORKER_NAME}.pem" ]]; then
    cat > ${WORKER_NAME}-csr.json <<EOF
{
  "CN": "system:node:${HOSTNAME}",
  "key": { "algo":"rsa","size":2048 },
  "names": [ { "C":"UK","L":"London","O":"system:nodes","OU":"StegHub.com DEVOPS","ST":"England"} ]
}
EOF

    cfssl gencert -ca=ca.pem -ca-key=ca-key.pem -config=ca-config.json \
      -hostname=${HOSTNAME},${PUBLIC_IP},127.0.0.1 \
      -profile=kubernetes ${WORKER_NAME}-csr.json | cfssljson -bare ${WORKER_NAME}

    echo "[INFO] Generated kubelet certificate for ${WORKER_NAME}"
  else
    echo "[INFO] Kubelet certificate for ${WORKER_NAME} already exists. Skipping."
  fi
done

#-------------------------
# Step 5: SCP Retry Function
#-------------------------
scp_retry() {
  local SRC_FILES="$1"
  local DEST_USER="$2"
  local DEST_IP="$3"
  local DEST_PATH="$4"
  local RETRIES=3
  local COUNT=0

  until scp -o StrictHostKeyChecking=no -i "$SSH_KEY" $SRC_FILES $DEST_USER@$DEST_IP:$DEST_PATH; do
    COUNT=$((COUNT+1))
    if [[ $COUNT -ge $RETRIES ]]; then
      echo "[ERROR] SCP to $DEST_IP failed after $RETRIES attempts."
      return 1
    fi
    echo "[WARN] SCP failed. Retrying in 5s..."
    sleep 5
  done
}

#-------------------------
# Step 6: Distribute Certificates to Worker Nodes
#-------------------------
echo "[INFO] Distributing certificates to worker nodes..."
for i in 0 1 2; do
  WORKER_NAME="${NAME}-worker-$i"
  PUBLIC_IP=$(aws ec2 describe-instances --region $REGION --filters "Name=tag:Name,Values=${WORKER_NAME}" --query "Reservations[0].Instances[0].PublicIpAddress" --output text)

  scp_retry "ca.pem ${WORKER_NAME}-key.pem ${WORKER_NAME}.pem" "$SSH_USER" "$PUBLIC_IP" "~/"
done

#-------------------------
# Step 7: Distribute Certificates to Master Nodes
#-------------------------
echo "[INFO] Distributing certificates to master nodes..."
for i in 0 1 2; do
  MASTER_NAME="${NAME}-master-$i"
  PUBLIC_IP=$(aws ec2 describe-instances --region $REGION --filters "Name=tag:Name,Values=${MASTER_NAME}" --query "Reservations[0].Instances[0].PublicIpAddress" --output text)

  scp_retry "ca.pem ca-key.pem service-account-key.pem service-account.pem master-kubernetes.pem master-kubernetes-key.pem" "$SSH_USER" "$PUBLIC_IP" "~/"
done

echo "[INFO] All certificates generated and distributed successfully!"
ls -ltr $PKI_DIR/*.pem
