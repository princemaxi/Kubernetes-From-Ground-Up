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
