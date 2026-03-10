# Orchestrating Containers Across Multiple Virtual Servers: Kubernetes From-Ground-Up

## 📖 Project Overview
Kubernetes is the de facto standard for container orchestration, offering an intuitive architecture and rich configuration options. While tools like minikube, kind, or kubeadm allow you to spin up clusters quickly for development, they abstract away the underlying complexity.

Installing, configuring, and securing a production-grade Kubernetes cluster is a highly complex engineering task. To truly understand the mechanics of a highly available and secure cluster, this project takes the "From-Ground-Up" approach. We bypass automated helpers and managed services to manually provision, configure, and connect every component from scratch.

## Key Administrator Responsibilities
By building this cluster manually, we implement the core responsibilities of a Kubernetes Administrator:

**1. Component Provisioning:** Installing and configuring Control Plane (Master) components and Worker Nodes.

**2. Cluster Security (PKI):** Applying stringent security settings, including:

- **In-Transit Encryption:** Securing network communications using HTTPS and manually generated TLS certificates.

- **At-Rest Encryption:** Encrypting sensitive data (like Secrets) stored on disk.

**3. Data Store Capacity Planning:** Configuring a highly available etcd cluster.

**4. Network Configuration:** Implementing Container Network Interfaces (CNI) for seamless Pod-to-Pod and Node-to-Node communication.

**5. Lifecycle Management:** Laying the groundwork for periodical cluster upgrades, observability, and auditing.

> ***Note:** Unless restricted by strict business or compliance requirements, production environments should default to Managed Kubernetes services (PaaS) such as Amazon EKS, Azure AKS, or Google GKE. Managed services provide hardened default security postures and drastically reduce the Total Cost of Ownership (TCO) for maintaining the Control Plane.*

## 🏛️ Project Architecture
Building a highly available Kubernetes cluster requires a robust infrastructure topology. This project deploys a secure, distributed architecture within a dedicated AWS Virtual Private Cloud (VPC).

### Infrastructure Components
- **Networking:** A custom VPC (172.31.0.0/16) with a public subnet (172.31.0.0/24), an Internet Gateway, and highly restrictive Security Groups.

- **Load Balancing:** An AWS Network Load Balancer (NLB) operating at Layer 4 (TCP) to distribute kubectl and worker node traffic evenly across the three Control Plane nodes without terminating the TLS connections.

- **Control Plane (Masters):** Three t2.micro Ubuntu 22.04 instances running the Kubernetes API Server, Scheduler, Controller Manager, and the distributed etcd key-value store.

- **Data Plane (Workers):** Three t2.micro Ubuntu 22.04 instances running containerd, kubelet, and kube-proxy, connected via a custom CNI bridge network.

- **Security:** End-to-end Mutual TLS (mTLS) generated manually via Cloudflare's cfssl, combined with AES-CBC encryption for data at rest within etcd.

![alt text](/images/ChatGPT%20Image%20Mar%2010,%202026,%2012_57_18%20PM.png)

# Implementation

## 🛠️ Step 0: Client Workstation Preparation
Before bootstrapping the cluster, the administrative workstation must be equipped with the necessary orchestration tools.

### 1. The Workstation Bootstrap Script
To ensure consistency and idempotency across environments, the following bash script automates the installation of all required client utilities.

- **Enter the command:** `nano install_k8s_tools.sh`
- **Paste this script and save:**
    ```bash
    #!/bin/bash

    set -e

    echo "Updating system packages..."
    sudo apt update -y

    echo "Installing required utilities..."
    sudo apt install -y curl wget unzip jq

    echo "Installing AWS CLI v2..."

    if command -v aws &> /dev/null
    then
        echo "AWS CLI already installed. Updating..."
        curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
        unzip -o awscliv2.zip
        sudo ./aws/install --update
        rm -rf aws awscliv2.zip
    else
        curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
        unzip awscliv2.zip
        sudo ./aws/install
        rm -rf aws awscliv2.zip
    fi

    echo "Installing kubectl..."
    curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"

    chmod +x kubectl
    sudo mv kubectl /usr/local/bin/

    echo "Installing CFSSL tools..."
    sudo apt install -y golang-cfssl

    echo "Creating kubectl alias..."
    if ! grep -q "alias k=kubectl" ~/.bashrc; then
        echo "alias k=kubectl" >> ~/.bashrc
    fi

    echo "Reloading bash..."
    source ~/.bashrc

    echo "Verifying installations..."
    aws --version
    kubectl version --client
    cfssl version

    echo "Installation Complete!"
    ```
- **Execute the script:** 
    ```bash
    chmod +x install_k8s_tools.sh
    ./install_k8s_tools.sh
    ```

    ![alt text](/images/0.png)
    ![alt text](/images/1.png)
    ![alt text](/images/2.png)
    ![alt text](/images/3.png)
    ![alt text](/images/4.png)

#### ⚙️ Script Execution Flow 
This bash script prepares your local Ubuntu workstation by automatically installing and configuring the exact versions of the tools required to bootstrap the cluster.

When you run this script, it performs the following actions in order:

- Updates Package Lists (apt update): Refreshes your local package index to ensure the system pulls the latest available software versions.

- Installs Core Dependencies: Downloads utility programs including curl and wget (for downloading binaries), unzip (for extracting AWS CLI), and jq (a JSON processor for parsing AWS and Kubernetes outputs).

- Installs/Updates AWS CLI v2: 
  - Checks if the aws command already exists on your machine. 
  - If it does, it downloads the latest package and runs the installer with the --update flag.
  - If it doesn't, it performs a fresh installation.
  - Finally, it cleans up by removing the downloaded .zip and extracted installation folders to save disk space.

- Installs Kubernetes CLI (kubectl):

  - Dynamically fetches the version number of the latest stable Kubernetes release.
  - Downloads the corresponding kubectl binary directly from Google's distribution servers.
  - Makes the downloaded file executable (chmod +x).
  - Moves it to /usr/local/bin/ so the command can be executed globally from any directory.

- Installs Certificate Tools: Installs Cloudflare's PKI toolkit (golang-cfssl), providing the cfssl and cfssljson commands needed to manually generate our cluster's TLS certificates later in the project.

- Configures Terminal Alias: Checks your ~/.bashrc file. If the shortcut alias k=kubectl isn't there, it appends it and immediately reloads your terminal session (source ~/.bashrc) so you can start typing k instead of kubectl to save time.

- Verifies Installation: Runs a quick version check (--version) for aws, kubectl, and cfssl to print out the installed versions and prove the system paths are configured correctly.

### 2. Configure AWS IAM Authentication

To interact with AWS services, ensure you have an IAM user with programmatic access. Generate your Access Keys and configure your environment:

```bash
aws configure --profile <your_username>
```

**Example input:**
```plaintext
AWS Access Key ID [None]: AKIAIOSFODNN7EXAMPLE
AWS Secret Access Key [None]: wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
Default region name [None]: us-west-2
Default output format [None]: json
```

**Verify your connection by querying your VPCs:**
```bash
aws ec2 describe-vpcs
```

![alt text](/images/5.png)

## ☁️ Step 1: Provisioning Cloud Infrastructure (AWS)
While industry standards dictate using Infrastructure as Code (IaC) tools like Terraform for provisioning, bootstrapping a cluster via the AWS CLI is a highly recommended rite of passage. This manual approach exposes the underlying API calls, solidifies networking fundamentals, and builds the troubleshooting muscle required for Senior Cloud/DevOps roles.

Once the "hard way" is mastered, this infrastructure can easily be codified into Terraform modules.

### Infrastructure Architecture
In this phase, we provision the foundational AWS resources required to host our cluster:

- **Networking:** A custom Virtual Private Cloud (VPC), Subnet, Internet Gateway (IGW), and Route Tables.

- **Security:** A Security Group acting as a virtual firewall for our nodes.

- **Load Balancing:** A Layer 4 Network Load Balancer (NLB) to distribute traffic to the Kubernetes API server.

- **Compute:** 6 EC2 instances (3 Control Plane nodes, 3 Worker nodes) running Ubuntu 22.04 LTS.

### The Infrastructure Automation Script
To streamline the execution of dozens of AWS CLI commands, the logic has been wrapped into an idempotent bash script: 
```bash
nano create-k8s-infra.sh
```

**Paste:**
```bash
#!/bin/bash
set -euo pipefail
set -x

# -----------------------------
# CONFIGURATION
# -----------------------------
NAME="k8s-cluster-from-ground-up"
REGION="eu-west-2"
VPC_CIDR="172.31.0.0/16"
SUBNET_CIDR="172.31.0.0/24"
STATE_FILE="./k8s-cluster.state"

export AWS_DEFAULT_REGION=$REGION

mkdir -p ssh
echo "=== Starting Kubernetes infrastructure setup in $REGION ==="

# -----------------------------
# 1️⃣ CREATE VPC
# -----------------------------
echo "Creating VPC..."
VPC_ID=$(aws ec2 create-vpc \
    --cidr-block $VPC_CIDR \
    --query 'Vpc.VpcId' \
    --output text)
aws ec2 create-tags --resources $VPC_ID --tags Key=Name,Value=$NAME
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-support '{"Value":true}'
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-hostnames '{"Value":true}'
echo "VPC: $VPC_ID" >> $STATE_FILE

# -----------------------------
# 2️⃣ CREATE SUBNET
# -----------------------------
SUBNET_ID=$(aws ec2 create-subnet \
    --vpc-id $VPC_ID \
    --cidr-block $SUBNET_CIDR \
    --query 'Subnet.SubnetId' \
    --output text)
aws ec2 create-tags --resources $SUBNET_ID --tags Key=Name,Value=$NAME
echo "Subnet: $SUBNET_ID" >> $STATE_FILE

# -----------------------------
# 3️⃣ INTERNET GATEWAY
# -----------------------------
IGW_ID=$(aws ec2 create-internet-gateway \
    --query 'InternetGateway.InternetGatewayId' \
    --output text)
aws ec2 attach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $VPC_ID
aws ec2 create-tags --resources $IGW_ID --tags Key=Name,Value=$NAME
echo "IGW: $IGW_ID" >> $STATE_FILE

# -----------------------------
# 4️⃣ ROUTE TABLE
# -----------------------------
ROUTE_TABLE_ID=$(aws ec2 create-route-table \
    --vpc-id $VPC_ID \
    --query 'RouteTable.RouteTableId' \
    --output text)
aws ec2 associate-route-table --route-table-id $ROUTE_TABLE_ID --subnet-id $SUBNET_ID
aws ec2 create-route --route-table-id $ROUTE_TABLE_ID --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW_ID
aws ec2 create-tags --resources $ROUTE_TABLE_ID --tags Key=Name,Value=$NAME
echo "RouteTable: $ROUTE_TABLE_ID" >> $STATE_FILE

# -----------------------------
# 5️⃣ SECURITY GROUP
# -----------------------------
SECURITY_GROUP_ID=$(aws ec2 create-security-group \
    --group-name $NAME \
    --description "Kubernetes cluster SG" \
    --vpc-id $VPC_ID \
    --query 'GroupId' \
    --output text)
aws ec2 create-tags --resources $SECURITY_GROUP_ID --tags Key=Name,Value=$NAME

# Add rules
aws ec2 authorize-security-group-ingress --group-id $SECURITY_GROUP_ID --protocol tcp --port 22 --cidr 0.0.0.0/0
aws ec2 authorize-security-group-ingress --group-id $SECURITY_GROUP_ID --protocol tcp --port 6443 --cidr 0.0.0.0/0
aws ec2 authorize-security-group-ingress --group-id $SECURITY_GROUP_ID --protocol tcp --port 2379-2380 --cidr $SUBNET_CIDR
aws ec2 authorize-security-group-ingress --group-id $SECURITY_GROUP_ID --protocol tcp --port 30000-32767 --cidr $SUBNET_CIDR
aws ec2 authorize-security-group-ingress --group-id $SECURITY_GROUP_ID --protocol icmp --port -1 --cidr 0.0.0.0/0
echo "SG: $SECURITY_GROUP_ID" >> $STATE_FILE

# -----------------------------
# 6️⃣ NETWORK LOAD BALANCER
# -----------------------------
LOAD_BALANCER_ARN=$(aws elbv2 create-load-balancer \
    --name $NAME \
    --subnets $SUBNET_ID \
    --scheme internet-facing \
    --type network \
    --query 'LoadBalancers[0].LoadBalancerArn' \
    --output text)
echo "LB: $LOAD_BALANCER_ARN" >> $STATE_FILE

TARGET_GROUP_ARN=$(aws elbv2 create-target-group \
    --name $NAME \
    --protocol TCP \
    --port 6443 \
    --vpc-id $VPC_ID \
    --target-type ip \
    --query 'TargetGroups[0].TargetGroupArn' \
    --output text)
echo "TG: $TARGET_GROUP_ARN" >> $STATE_FILE

aws elbv2 create-listener \
    --load-balancer-arn $LOAD_BALANCER_ARN \
    --protocol TCP \
    --port 6443 \
    --default-actions Type=forward,TargetGroupArn=$TARGET_GROUP_ARN

KUBERNETES_PUBLIC_ADDRESS=$(aws elbv2 describe-load-balancers \
    --load-balancer-arns $LOAD_BALANCER_ARN \
    --query 'LoadBalancers[0].DNSName' \
    --output text)
echo "Kubernetes Public Address: $KUBERNETES_PUBLIC_ADDRESS"
echo "PublicAddress: $KUBERNETES_PUBLIC_ADDRESS" >> $STATE_FILE

# -----------------------------
# 7️⃣ UBUNTU AMI
# -----------------------------
IMAGE_ID=$(aws ec2 describe-images \
    --owners 099720109477 \
    --filters "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*" \
    --query 'Images | sort_by(@,&CreationDate) | [-1].ImageId' \
    --output text)
echo "AMI: $IMAGE_ID" >> $STATE_FILE

# -----------------------------
# 8️⃣ SSH KEY
# -----------------------------
aws ec2 create-key-pair --key-name $NAME --query 'KeyMaterial' --output text > ssh/$NAME.pem
chmod 400 ssh/$NAME.pem
echo "Key: $NAME.pem" >> $STATE_FILE

# -----------------------------
# 9️⃣ CREATE MASTER NODES
# -----------------------------
for i in 0 1 2; do
  INSTANCE_ID=$(aws ec2 run-instances \
    --image-id $IMAGE_ID \
    --count 1 \
    --instance-type t2.micro \
    --key-name $NAME \
    --security-group-ids $SECURITY_GROUP_ID \
    --subnet-id $SUBNET_ID \
    --private-ip-address 172.31.0.1$i \
    --associate-public-ip-address \
    --query 'Instances[0].InstanceId' \
    --output text)
  aws ec2 create-tags --resources $INSTANCE_ID --tags Key=Name,Value=$NAME-master-$i
  echo "Master-$i: $INSTANCE_ID" >> $STATE_FILE
done

# -----------------------------
# 10️⃣ CREATE WORKER NODES
# -----------------------------
for i in 0 1 2; do
  INSTANCE_ID=$(aws ec2 run-instances \
    --image-id $IMAGE_ID \
    --count 1 \
    --instance-type t2.micro \
    --key-name $NAME \
    --security-group-ids $SECURITY_GROUP_ID \
    --subnet-id $SUBNET_ID \
    --private-ip-address 172.31.0.2$i \
    --associate-public-ip-address \
    --query 'Instances[0].InstanceId' \
    --output text)
  aws ec2 create-tags --resources $INSTANCE_ID --tags Key=Name,Value=$NAME-worker-$i
  echo "Worker-$i: $INSTANCE_ID" >> $STATE_FILE
done

echo "=== Kubernetes infrastructure setup complete! ==="
echo "State saved in $STATE_FILE"
```

**Run these commands to execute the script:**
```bash
chmod +x create-k8s-infra.sh
./create-k8s-infra.sh
```

![alt text](/images/6.png)
![alt text](/images/7.png)
![alt text](/images/8.png)
![alt text](/images/9.png)
![alt text](/images/11a.png)
![alt text](/images/11.png)
![alt text](/images/12.png)
![alt text](/images/13.png)
![alt text](/images/14.png)

#### ⚙️ Script Execution Flow
This script automates the creation of a strictly defined AWS environment. Here is the engineering breakdown of the operations:

**1. State Management (k8s-cluster.state):** Mimicking how Terraform uses .tfstate files, this script actively logs the AWS Resource IDs (VPC, Subnet, EC2 instances) to a local file. This is crucial for tracking the infrastructure footprint and allowing for an automated teardown later.

**2. Network Foundation (Steps 1-4):** Provisions a VPC (172.31.0.0/16) and a single public subnet. Crucially, it enables dns-hostnames and dns-support on the VPC, which Kubernetes requires to resolve internal node names.

**3. Security Group Firewall (Step 5):** Applies strict ingress rules required for a Kubernetes cluster:

  - TCP 6443: Kubernetes API Server.
  - TCP 2379-2380: etcd server client API (Internal Subnet only).
  - TCP 30000-32767: NodePort Services (Internal Subnet only).
  - TCP 22: SSH access. (Note: In a true production environment, 0.0.0.0/0 should be restricted to a specific administrative IP or VPN CIDR).

**4. Network Load Balancer (Step 6):** Provisions an AWS NLB (Layer 4) instead of an ALB (Layer 7). The Kubernetes API uses mutual TLS (mTLS); an NLB performs TCP passthrough, ensuring the SSL termination happens directly on the Kube-APIServer, preserving the cryptographic trust.

**5. Dynamic AMI Fetching (Step 7):** Queries the AWS API to dynamically find the latest official Ubuntu 22.04 LTS (Jammy) image ID, rather than hardcoding an outdated AMI.

**6. Predictable Compute Provisioning (Steps 9-10):** Uses bash for loops to provision 3 Master nodes and 3 Worker nodes.

  - Explicit IP Allocation: Instead of relying on DHCP, the script explicitly assigns private IPs (172.31.0.1x for Masters, 172.31.0.2x for Workers). This predictability is absolutely mandatory for generating valid SSL/TLS certificates (PKI) in the next phase.

## 🔐 Step 2: Provisioning the Public Key Infrastructure (PKI) and TLS Certificates
In a production Kubernetes cluster, security cannot be an afterthought. Kubernetes employs Mutual TLS (mTLS) for all communication between its internal components. This means components don't just encrypt their traffic; they mathematically prove their identity to one another before any data is exchanged.

Because we are building this cluster "From-Ground-Up," we cannot rely on a cloud provider to manage these identities. We must act as our own Certificate Authority (CA) and manually provision the cryptographic keys for every component.

### 🧠 Core Concepts: Who Needs Certificates?
Every node and service in the cluster requires a specific certificate to authenticate against the kube-apiserver (the brain of the cluster).

#### Control Plane (Master) Components:

- **kube-apiserver:** Requires a Server Certificate (must include all Master IPs, the NLB address, and internal cluster DNS names)
- **kube-controller-manager:** Requires a Client Certificate.
- **kube-scheduler:** Requires a Client Certificate.
- **etcd:** Requires Server/Client Certificates for peer-to-peer data replication.
- **service-account:** Requires a dedicated Key Pair to sign token requests for Pods.

#### Worker Node Components:

- **kube-proxy:** Requires a Client Certificate (system:node-proxier).
- **kubelet:** Requires a highly specific Client Certificate. To satisfy the Kubernetes Node Authorizer security policy, a Kubelet's certificate must be in the system:nodes group and its Common Name (CN) must perfectly match its hostname (`system:node:<nodeName>`).


### ⚙️ The Automation Script: End-to-End PKI Generation & Distribution
Generating 10+ certificates manually using cfssl is highly prone to human error (e.g., missing an IP in the Subject Alternative Name list). To ensure accuracy and repeatability, this automated, idempotent bash script handles the entire lifecycle: generating the CA, signing the certificates, and securely distributing them to the EC2 instances.

**Run the command:**

```bash
nano k8s-PKI-generator-distributor
```

**Then Paste:**

```bash
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
# Create CA if not exists
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
# API Server Certificate
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
# Client Certificates Function
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
# Kubelet Worker Certificates
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
# SCP Retry Function & Distribution
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

echo "[INFO] Distributing certificates to worker nodes..."
for i in 0 1 2; do
  WORKER_NAME="${NAME}-worker-$i"
  PUBLIC_IP=$(aws ec2 describe-instances --region $REGION --filters "Name=tag:Name,Values=${WORKER_NAME}" --query "Reservations[0].Instances[0].PublicIpAddress" --output text)

  scp_retry "ca.pem ${WORKER_NAME}-key.pem ${WORKER_NAME}.pem" "$SSH_USER" "$PUBLIC_IP" "~/"
done

echo "[INFO] Distributing certificates to master nodes..."
for i in 0 1 2; do
  MASTER_NAME="${NAME}-master-$i"
  PUBLIC_IP=$(aws ec2 describe-instances --region $REGION --filters "Name=tag:Name,Values=${MASTER_NAME}" --query "Reservations[0].Instances[0].PublicIpAddress" --output text)

  scp_retry "ca.pem ca-key.pem service-account-key.pem service-account.pem master-kubernetes.pem master-kubernetes-key.pem" "$SSH_USER" "$PUBLIC_IP" "~/"
done

echo "[INFO] All certificates generated and distributed successfully!"
```

![alt text](/images/15.png)
![alt text](/images/16.png)
![alt text](/images/17.png)
![alt text](/images/18.png)

#### ⚙️ Script Execution Flow 
When executed, this script dynamically interacts with AWS, generates the necessary cryptographic assets, and pushes them to the correct servers.

**1. Dynamic Environment Discovery:** Instead of hardcoding IP addresses, the script queries the AWS API to dynamically fetch the DNS name of the Network Load Balancer (NLB) and the private/public IPs of all 6 running EC2 instances.

**2. Root Certificate Authority (CA) Initialization:** Generates ca.pem and ca-key.pem. This is the absolute root of trust for the entire cluster.

**3. API Server Certificate Generation:** Generates the API Server certificate. Crucially, it injects the previously discovered NLB DNS, the internal Kubernetes DNS names, and the Master Private IPs into the hosts array. If any of these are missing, the worker nodes will refuse to connect.

**4. Client Certificate Generation:** Uses a modular bash function to rapidly generate the standard client certificates for the Scheduler, Controller Manager, Kube-Proxy, Admin user, and Service Accounts.

**5. Kubelet Certificate Generation:** Loops through the 3 Worker node IPs to generate node-specific certificates. It strictly enforces the system:node:<PrivateIP> naming convention required by the Node Authorizer.

**6. Secure Network Distribution:** Uses scp (Secure Copy Protocol) to push the files over SSH to the EC2 instances.

  - Worker Nodes receive only the public ca.pem and their own specific node keypair.

  - Master Nodes receive the CA, the API server keypair, and the Service Account keypair.

> ***Engineering Note:** The script uses a custom scp_retry function with a 5-second backoff. This prevents the script from failing completely if an EC2 instance experiences a momentary network hiccup or hasn't fully initialized its SSH daemon.*


## 📝 Step 3: Generating Kubernetes Configuration Files (Kubeconfigs)
With the PKI infrastructure in place, our cluster components have the cryptographic keys they need to prove their identities. However, having a key is only half the battle; the clients also need to know where the Kubernetes API server is located and how to present those keys.

This is handled by Kubeconfig files. A kubeconfig is a YAML file used to organize information about clusters, users, namespaces, and authentication mechanisms.

### 🧠 Core Concepts: The Anatomy of a Kubeconfig
Each file generated in this step binds three critical pieces of information together into a context:

**1. Cluster:** The endpoint of the API Server (e.g., the Network Load Balancer DNS or localhost) and the Root CA certificate to verify the server's identity.

**2. Credentials:** The specific Client Certificate and Private Key generated in Step 2.

**3. Context:** Binds the specific user (credentials) to the specific cluster.

### Architectural Routing Decisions
- **Worker Nodes & Admin (kubelet, kube-proxy, admin):** These configurations point to the Network Load Balancer (NLB) public address. This ensures that if a single Master node fails, the Load Balancer will seamlessly route their traffic to a healthy Control Plane instance.

- **Master Components (kube-controller-manager, kube-scheduler):** Because these services run directly on the Control Plane alongside the API Server, their configurations point to `https://127.0.0.1:6443`. Routing this traffic out to the external NLB and back in would introduce unnecessary network latency and points of failure.

### ⚙️ The Automation Script: Kubeconfig Generation & Distribution
Using the `kubectl config` command manually for 6 different nodes is tedious. This idempotent bash script automates the creation of all required Kubeconfigs by embedding the TLS certificates directly into the files and securely distributing them via SCP.

**Create the bash script:**
```bash
nano generate-kubeconfig-files.sh
```

**Paste:**
```bash
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
```

**Execute the script:**
```bash
chmod +x generate-kubeconfig-files.sh
./generate-kubeconfig-files.sh
```

![alt text](/images/19.png)
![alt text](/images/20.png)

#### ⚙️ Script Execution Flow (What this script does)
- **Environment Discovery:** Automatically queries the AWS API to locate the NLB's DNS name (for external routing) and the public IPs of all instances (for SCP distribution).

- **Kubelet Context Initialization:** Iterates through the worker nodes, creating a dedicated kubeconfig for each. It strictly binds the `system:node:<hostname>` identity to the Load Balancer endpoint.

- **Control Plane Initialization:** Generates specific kubeconfigs for the kube-proxy, kube-controller-manager, and kube-scheduler, setting the server endpoints appropriately (127.0.0.1 vs. NLB).

- **Certificate Embedding (--embed-certs=true):** Rather than pointing to files on a local hard drive, this flag embeds the raw base64-encoded TLS certificates directly into the kubeconfig file. This creates highly portable configuration files that can be moved between machines without breaking.

- **Secure Distribution:** Automatically pushes the generated files to their respective target environments. Master nodes receive the controller/scheduler configs, while Worker nodes receive their node-specific kubelet configs.


## 🗄️Step 4: Bootstrapping the Distributed etcd Cluster & Encryption at Rest
Kubernetes itself is inherently stateless; it relies entirely on a highly available, distributed key-value store called etcd to persist cluster state, application configurations, and sensitive secrets. Because etcd is the "brain" and "memory" of the cluster, its availability and security are paramount.

### 🧠 Core Concepts: Securing etcd
Securing a Kubernetes data store requires a two-pronged approach:

- **In-Transit Encryption:** Protecting data as it moves across the network. This is achieved using the Mutual TLS (mTLS) certificates we generated in Step 2.

- **At-Rest Encryption:** Protecting data when it is physically written to the disk. By default, Kubernetes stores objects (including Secrets) in plaintext within etcd. If an attacker compromises the underlying EC2 volume, they gain full access to cluster secrets. We mitigate this by configuring an EncryptionConfig.

### Part A: Generating the Data Encryption Config
Before starting the etcd service, we must generate a cryptographic key to encrypt the data at rest using the AES-CBC provider.

Run the following command on your local workstation to generate a 64-byte random key encoded in base64, and output it into a Kubernetes EncryptionConfig file:
```bash
ETCD_ENCRYPTION_KEY=$(head -c 32 /dev/urandom | base64)

cat > encryption-config.yaml <<EOF
kind: EncryptionConfig
apiVersion: v1
resources:
  - resources:
      - secrets
    providers:
      - aescbc:
          keys:
            - name: key1
              secret: ${ETCD_ENCRYPTION_KEY}
      - identity: {}
EOF
```

***Note:** This file must be distributed to the Control Plane nodes alongside the Kubeconfigs, as the kube-apiserver will use it to encrypt/decrypt data.*

### Part B: The etcd Bootstrap Script
Bootstrapping a distributed consensus cluster requires exact coordination. The nodes must know about each other at startup to form a quorum. The following script automates the installation, configuration, and secure peering of a 3-node etcd cluster.

**Create the file:**
```bash
nano etcd-bootstrap.sh
```

**Paste:**
```bash
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
```

![alt text](/images/21.png)
![alt text](/images/22.png)
![alt text](/images/23.png)

## 🧠 Step 5: Bootstrapping the Kubernetes API Server
With the etcd database cluster healthy, we can now provision the core "brain" of Kubernetes: the Control Plane.

In this specific step, we will bootstrap the Kubernetes API Server (kube-apiserver). This component is the front-end of the cluster; it exposes the Kubernetes API and is the only component that communicates directly with the etcd datastore. All other components (schedulers, controllers, worker nodes, and external users) communicate with the cluster exclusively through this REST API.

### ⚙️ The Automation Script: API Server Bootstrap
Provisioning the API Server manually involves moving dozens of certificates and passing highly specific cryptographic flags to systemd. This idempotent bash script automates the directory scaffolding, binary installation, and the kube-apiserver.service deployment across all Master nodes in parallel.

**Create the file:**
```bash
nano k8s-control-plane.sh
```

**Paste:**

```bash
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
```

**Execute:**
```bash
chmod +x k8s-control-plane.sh
./k8s-control-plane.sh
```

![alt text](/images/24.png)
![alt text](/images/25.png)
![alt text](/images/26.png)

### 🛠️ Key Architectural Decisions & Configurations
The kube-apiserver.service file is the most complex configuration in the cluster. Critical flags include:

- **Authorization (--authorization-mode=Node,RBAC):** Enforces Role-Based Access Control and enables the specific Node Authorizer policy.

- **Admission Control (--enable-admission-plugins=NamespaceLifecycle,NodeRestriction...):** NodeRestriction is vital here; it prevents a compromised worker node from modifying the labels or status of other nodes in the cluster.

- **Encryption (--encryption-provider-config):** Points to the encryption-config.yaml generated previously, ensuring secrets are encrypted before being written to etcd.

- **State Management (--etcd-servers):** Dynamically points the API Server to all three highly available etcd nodes.

### 🕵️ Troubleshooting: 
The API Server "Trap" If following standard manual documentation, you may notice the kube-apiserver failing to start. Investigating systemd logs is a core competency:
```bash
journalctl -u kube-apiserver -e --no-pager
```

### Common Pitfall: 
A frequent trap during manual configuration is a mismatch in the etcd configuration. If the API Server is instructed to connect to etcd using HTTPS (--etcd-servers=https://...), but etcd was accidentally configured to listen on HTTP, the API server will crash loop with a "connection refused" or "TLS handshake error." Ensuring the mTLS flags match precisely between the etcd.service and kube-apiserver.service is critical.

## 🔐 Step 6: Configuring RBAC for Kubelet Authorization
In Kubernetes, security is a two-way street. In Step 2, we configured the Worker Nodes (kubelet) to authenticate themselves to the kube-apiserver. However, the reverse must also be explicitly permitted.

By default, the kube-apiserver does not have the authorization required to access the kubelet API on the Worker Nodes. If we skip this step, core administrative commands like kubectl exec, kubectl logs, and kubectl top (for metrics) will fail because the API Server's requests to the worker nodes will be explicitly denied.

### 🧠 Core Concepts: ClusterRoles and Bindings
To grant this access, we leverage Kubernetes Role-Based Access Control (RBAC):

**1. ClusterRole:** Defines what actions are allowed. We create a role (system:kube-apiserver-to-kubelet) that specifically allows interactions with the nodes/proxy, nodes/stats, nodes/log, nodes/spec, and nodes/metrics API endpoints.

**2. ClusterRoleBinding:** Defines who is allowed to perform those actions. We bind the newly created role to the kubernetes user, which is the identity the kube-apiserver uses when making outbound requests to the Kubelets.

### ⚙️ The Automation Script: RBAC Initialization
Because RBAC configurations are stored centrally in etcd as part of the cluster state, we do not need to execute this across all nodes. This script connects to a single Control Plane node and applies the declarative YAML configuration directly to the API Server.

**Create the file:**
```
nano configure-kubelet-rbac.sh
```

**Paste:**
```bash
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
```

![alt text](/images/rbac.png)
![alt text](/images/28.png)
![alt text](/images/29.png)

### ⚙️ Script Execution Flow (What this script does)
- **Targeted Execution:** Uses SSH to connect to just one of the Control Plane Master nodes (13.40.3.245).

- **Declarative Pipeline (`cat <<YAML | kubectl apply -f -`):** Instead of copying a physical .yaml file over the network, this command uses a bash heredoc to stream the declarative RBAC definitions directly into the kubectl apply command via standard input.

- **API Authentication:** Forces kubectl to use the high-privileged admin.kubeconfig (generated in Step 3) to authenticate the request against the local kube-apiserver instance listening on `127.0.0.1:6443`.

- **Immediate Verification:** Runs a quick kubectl get nodes check. (*Note: Since the worker nodes have not been bootstrapped yet, no nodes will be returned, but a successful exit code 0 confirms the API server processed the authorized request without an RBAC forbidden error*).

## 🏗️ Step 7: Bootstrapping the Worker Nodes (Data Plane)
While the Control Plane acts as the brain of the cluster, the Worker Nodes (or the Data Plane) are the muscle. These nodes are responsible for actually running the containerized applications and workloads.

Each Worker Node requires three core components to function:

**1. Container Runtime (containerd):** The software responsible for pulling images and running the containers.

**2. kubelet:** The primary "node agent" that registers the node with the cluster, watches for pod assignments, and ensures containers are healthy.

**3. kube-proxy:** A network proxy that maintains network rules on nodes, allowing network communication to your Pods from network sessions inside or outside of your cluster.

### Phase 1: OS Dependencies & Container Runtime Installation
Before Kubernetes can schedule workloads, the host operating system must be prepared. This involves disabling swap memory (to allow the kubelet to accurately manage resource allocation) and installing critical networking dependencies:

- **socat:** Required for the kubectl port-forward command to function.

- **conntrack:** A Linux kernel feature used by Kubernetes to track logical network connections and route packets consistently.

- **ipset:** An extension to iptables that enables high-performance firewall rules, essential for Kubernetes Network Policies.

- **Automation Script 1:** Runtime Provisioning
This script concurrently connects to all worker nodes, installs the OS dependencies, and provisions the containerd runtime and CNI binaries.

**Create the file:**
```bash
nano bootstrap-workers.sh
```

**Paste:**
```bash
#!/bin/bash
set -euo pipefail

# --- CONFIG ---
SSH_KEY="./ssh/k8s-cluster-from-ground-up.pem"
SSH_USER="ubuntu"
# Replace these with the actual Public IPs of your Worker nodes
WORKER_IPS=("35.179.154.34" "35.177.215.83" "18.171.211.27") 

bootstrap_worker() {
    local worker_ip=$1
    echo "[INFO][$worker_ip] Starting bootstrap process..."

    ssh -i "$SSH_KEY" "$SSH_USER@$worker_ip" bash -s <<EOF
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
for ip in "\${WORKER_IPS[@]}"; do
    bootstrap_worker "$ip" &
done
wait

echo "[INFO] All worker nodes have been successfully bootstrapped with binaries and container runtimes!"
```

**Execute:**
```bash
chmod +x bootstrap-workers.sh
./bootstrap-workers.sh
```

![alt text](/images/30.png)
![alt text](/images/31.png)
![alt text](/images/32.png)

### Phase 2: Configuring Kubelet, Kube-Proxy, and Networking
With containerd running, the final step is to configure the Kubernetes networking logic and start the worker agents.

Kubernetes assumes a flat networking model where all pods can communicate with each other, regardless of which node they reside on. To achieve this, we configure a Container Network Interface (CNI) bridge network using the dedicated POD_CIDR block assigned to each specific worker node.

Automation Script 2: Kubernetes Agent Configuration
This script dynamically configures the CNI bridge interface, moves the cryptographic keys and kubeconfigs we distributed earlier into their strict system paths, and generates the systemd files for kubelet and kube-proxy.

**Create the file:**
```bash
nano configure-workers.sh
```

**Paste:**
```bash
#!/bin/bash
set -euo pipefail

# --- CONFIG ---
SSH_KEY="./ssh/k8s-cluster-from-ground-up.pem"
SSH_USER="ubuntu"

# Array format: "IP_ADDRESS WORKER_NAME POD_CIDR"
# Note: Ensure the POD_CIDR blocks do not overlap with your VPC CIDR
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
```

**Execute:**
```bash
chmod +x configure-workers.sh
./configure-workers.sh
```

![alt text](/images/33.png).
![alt text](/images/34.png)

### ⚙️ Script Execution Flow 
- **Dynamic Network Mapping:** We define an array that explicitly ties a specific node IP to its assigned POD_CIDR block. This ensures that IP conflicts do not occur across the flat network.

- **CNI Implementation:** Configures a basic bridge network for local container routing and a loopback interface for internal component logic.

- **Kubelet CoreDNS Integration:** Tells the kubelet that `10.32.0.10` is the cluster's internal DNS server (CoreDNS). Once workloads are deployed, the kubelet will automatically inject this nameserver into every container's `/etc/resolv.conf`.

- **Service Binding:** Binds the kubelet directly to the containerd UNIX socket (unix:///var/run/containerd/containerd.sock).

- **Node Registration:** Restarts the daemons, causing the kubelet to reach out to the Control Plane (via the NLB) using its mTLS certificates and officially register the node as Ready.

## Confirm Node Readiness
Verify that the worker nodes have successfully bootstrapped containerd, generated their bridge networks, and authenticated to the API server.

```bash
kubectl get nodes --kubeconfig admin.kubeconfig -o wide
```
![alt text](/images/36.png)

## 🛠️ Troubleshooting 
A major objective of the "From-Ground-Up" approach is encountering and resolving the strict operational requirements of Kubernetes and modern DevOps workflows. Below are the key challenges resolved during this build, including a deep-dive post-mortem on a critical control plane failure.

Deep Dive: Kubernetes API Server Timeout & etcd Network Routing
Symptom: When attempting to query the cluster via the Load Balancer, the request timed out:

```Bash
kubectl --kubeconfig=/var/lib/kubernetes/admin.kubeconfig get nodes
```
### Error: Unable to connect to the server: dial tcp 18.132.28.22:6443: i/o timeout

#### Investigation & Diagnostics:

Service Status: Verified kube-apiserver was active and running via systemctl status kube-apiserver.

Port Binding: Confirmed the API server was actively listening on port 6443 using sudo ss -tulnp | grep 6443.

Local API Test: Ran `curl -k https://127.0.0.1:6443/version` locally on the master node. It returned Connection reset by peer, indicating a TLS/backend failure rather than a stopped service.

etcd Health Check: Queried the database cluster directly. All three nodes reported as healthy and successfully joined the quorum:

```Bash
sudo ETCDCTL_API=3 etcdctl --endpoints=https://172.31.0.10:2379... endpoint health
sudo ETCDCTL_API=3 etcdctl ... member list
```
Network Connectivity Validation: * Used `nc -vz 172.31.0.11 2379` to verify VPC networking between master nodes succeeded.

Verified Security Groups explicitly allowed 2379-2380 (etcd) and 6443 (API).

Used `nc -vz 18.132.28.22 6443` to test the Load Balancer, which yielded a Connection timed out, confirming the NLB could not establish a healthy target connection to the masters.

Root Cause:
The kube-apiserver was misconfigured to connect to the etcd database using AWS Public IP addresses instead of internal VPC addresses.

Incorrect: `--etcd-servers=https://13.x.x.x:2379`

Correct: `--etcd-servers=https://172.31.0.10:2379,https://172.31.0.11:2379,https://172.31.0.12:2379`

Using public endpoints caused unstable communication and asymmetric routing between the API server and the etcd cluster, failing the NLB health checks and dropping external traffic.

Remediation:
Edited `/etc/systemd/system/kube-apiserver.service` to route etcd traffic exclusively over the private subnet. Reloaded the daemon (systemctl daemon-reload) and restarted the service. Internal communication was instantly restored, and the Load Balancer targets became healthy.

### Key Lessons Learned:

- Always use private VPC IP addresses for internal Kubernetes component communication to ensure security and network stability.

- Validate etcd cluster health before troubleshooting the API server.

- Use standard networking utilities (ss, nc, curl) for systematic, layer-by-layer debugging.

### Additional Infrastructure Resolutions
- The ETCD initial-cluster-state Trap: During automation, the --initial-cluster-state flag was mistakenly set to existing. For a brand-new cluster bootstrap, this must explicitly be set to new to allow the independent nodes to form a quorum.

- Kubelet Authorization (RBAC) Denials: The API server initially threw Forbidden errors when executing kubectl logs. This was resolved by manually binding a ClusterRole (system:kube-apiserver-to-kubelet) to grant the API server cryptographic authority to access the worker node Kubelet APIs.
