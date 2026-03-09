#!/bin/bash
#====================================================
# Kubernetes Kubeconfig Generator & Distributor
#====================================================

set -euo pipefail

#-------------------------
# CONFIGURATION
#-------------------------
NAME="k8s-cluster-from-ground-up"
REGION="eu-west-2"
PKI_DIR="$HOME/k8s-pki"
SSH_KEY="$PWD/ssh/$NAME.pem"
SSH_USER="ubuntu"

cd "$PKI_DIR"
export AWS_DEFAULT_REGION=$REGION

#-------------------------
# Fetch Kubernetes API Server Address (NLB)
#-------------------------
KUBERNETES_API_SERVER_ADDRESS=$(aws elbv2 describe-load-balancers \
    --names "$NAME" \
    --query 'LoadBalancers[0].DNSName' \
    --output text)

echo "[INFO] Kubernetes API Server Address: $KUBERNETES_API_SERVER_ADDRESS"

#-------------------------
# Fetch Worker & Master Public IPs
#-------------------------
WORKERS=()
MASTERS=()
for i in 0 1 2; do
    WORKER_NAME="${NAME}-worker-$i"
    WORKER_IP=$(aws ec2 describe-instances --region $REGION \
        --filters "Name=tag:Name,Values=${WORKER_NAME}" "Name=instance-state-name,Values=running" \
        --query "Reservations[0].Instances[0].PublicIpAddress" --output text)
    WORKERS+=("$WORKER_IP")

    MASTER_NAME="${NAME}-master-$i"
    MASTER_IP=$(aws ec2 describe-instances --region $REGION \
        --filters "Name=tag:Name,Values=${MASTER_NAME}" "Name=instance-state-name,Values=running" \
        --query "Reservations[0].Instances[0].PublicIpAddress" --output text)
    MASTERS+=("$MASTER_IP")
done

echo "[INFO] Worker IPs: ${WORKERS[@]}"
echo "[INFO] Master IPs: ${MASTERS[@]}"

#-------------------------
# SCP Retry Function
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
# Step 1: Generate Worker Kubeconfigs
#-------------------------
for i in 0 1 2; do
    WORKER_NAME="${NAME}-worker-$i"
    INSTANCE_HOSTNAME="ip-172-31-0-2${i}"  # same hostname used in kubelet cert
    KUBECONFIG_FILE="${WORKER_NAME}.kubeconfig"

    if [[ -f "$KUBECONFIG_FILE" ]]; then
        echo "[INFO] $KUBECONFIG_FILE already exists. Skipping."
        continue
    fi

    echo "[INFO] Generating kubeconfig for $WORKER_NAME..."
    kubectl config set-cluster $NAME \
        --certificate-authority=ca.pem \
        --embed-certs=true \
        --server=https://$KUBERNETES_API_SERVER_ADDRESS:6443 \
        --kubeconfig=$KUBECONFIG_FILE

    kubectl config set-credentials system:node:$INSTANCE_HOSTNAME \
        --client-certificate=${WORKER_NAME}.pem \
        --client-key=${WORKER_NAME}-key.pem \
        --embed-certs=true \
        --kubeconfig=$KUBECONFIG_FILE

    kubectl config set-context default \
        --cluster=$NAME \
        --user=system:node:$INSTANCE_HOSTNAME \
        --kubeconfig=$KUBECONFIG_FILE

    kubectl config use-context default --kubeconfig=$KUBECONFIG_FILE
done

#-------------------------
# Step 2: Generate Kube-Proxy Kubeconfig
#-------------------------
if [[ ! -f kube-proxy.kubeconfig ]]; then
    echo "[INFO] Generating kube-proxy kubeconfig..."
    kubectl config set-cluster $NAME \
        --certificate-authority=ca.pem \
        --embed-certs=true \
        --server=https://$KUBERNETES_API_SERVER_ADDRESS:6443 \
        --kubeconfig=kube-proxy.kubeconfig

    kubectl config set-credentials system:kube-proxy \
        --client-certificate=kube-proxy.pem \
        --client-key=kube-proxy-key.pem \
        --embed-certs=true \
        --kubeconfig=kube-proxy.kubeconfig

    kubectl config set-context default \
        --cluster=$NAME \
        --user=system:kube-proxy \
        --kubeconfig=kube-proxy.kubeconfig

    kubectl config use-context default --kubeconfig=kube-proxy.kubeconfig
fi

#-------------------------
# Step 3: Generate Controller-Manager Kubeconfig
#-------------------------
if [[ ! -f kube-controller-manager.kubeconfig ]]; then
    echo "[INFO] Generating kube-controller-manager kubeconfig..."
    kubectl config set-cluster $NAME \
        --certificate-authority=ca.pem \
        --embed-certs=true \
        --server=https://127.0.0.1:6443 \
        --kubeconfig=kube-controller-manager.kubeconfig

    kubectl config set-credentials system:kube-controller-manager \
        --client-certificate=kube-controller-manager.pem \
        --client-key=kube-controller-manager-key.pem \
        --embed-certs=true \
        --kubeconfig=kube-controller-manager.kubeconfig

    kubectl config set-context default \
        --cluster=$NAME \
        --user=system:kube-controller-manager \
        --kubeconfig=kube-controller-manager.kubeconfig

    kubectl config use-context default --kubeconfig=kube-controller-manager.kubeconfig
fi

#-------------------------
# Step 4: Generate Scheduler Kubeconfig
#-------------------------
if [[ ! -f kube-scheduler.kubeconfig ]]; then
    echo "[INFO] Generating kube-scheduler kubeconfig..."
    kubectl config set-cluster $NAME \
        --certificate-authority=ca.pem \
        --embed-certs=true \
        --server=https://127.0.0.1:6443 \
        --kubeconfig=kube-scheduler.kubeconfig

    kubectl config set-credentials system:kube-scheduler \
        --client-certificate=kube-scheduler.pem \
        --client-key=kube-scheduler-key.pem \
        --embed-certs=true \
        --kubeconfig=kube-scheduler.kubeconfig

    kubectl config set-context default \
        --cluster=$NAME \
        --user=system:kube-scheduler \
        --kubeconfig=kube-scheduler.kubeconfig

    kubectl config use-context default --kubeconfig=kube-scheduler.kubeconfig
fi

#-------------------------
# Step 5: Generate Admin Kubeconfig
#-------------------------
if [[ ! -f admin.kubeconfig ]]; then
    echo "[INFO] Generating admin kubeconfig..."
    kubectl config set-cluster $NAME \
        --certificate-authority=ca.pem \
        --embed-certs=true \
        --server=https://$KUBERNETES_API_SERVER_ADDRESS:6443 \
        --kubeconfig=admin.kubeconfig

    kubectl config set-credentials admin \
        --client-certificate=admin.pem \
        --client-key=admin-key.pem \
        --embed-certs=true \
        --kubeconfig=admin.kubeconfig

    kubectl config set-context default \
        --cluster=$NAME \
        --user=admin \
        --kubeconfig=admin.kubeconfig

    kubectl config use-context default --kubeconfig=admin.kubeconfig
fi

#-------------------------
# Step 6: Distribute Kubeconfigs
#-------------------------
echo "[INFO] Distributing worker kubeconfigs..."
for i in 0 1 2; do
    WORKER_NAME="${NAME}-worker-$i"
    PUBLIC_IP="${WORKERS[$i]}"
    scp_retry "${WORKER_NAME}.kubeconfig" "$SSH_USER" "$PUBLIC_IP" "~/"
done

echo "[INFO] Distributing master kubeconfigs..."
for i in 0 1 2; do
    MASTER_NAME="${NAME}-master-$i"
    PUBLIC_IP="${MASTERS[$i]}"
    scp_retry "kube-controller-manager.kubeconfig kube-scheduler.kubeconfig admin.kubeconfig" "$SSH_USER" "$PUBLIC_IP" "~/"
done

echo "[INFO] Kubeconfig generation and distribution complete!"
ls -ltr *.kubeconfig
