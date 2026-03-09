#!/bin/bash
set -euo pipefail

STATE_FILE="./k8s-cluster.state"

if [ ! -f "$STATE_FILE" ]; then
    echo "State file $STATE_FILE not found. Nothing to delete."
    exit 1
fi

echo "=== Starting Kubernetes infrastructure cleanup ==="

# -----------------------------
# Load state file
# -----------------------------
declare -A STATE

while IFS=": " read -r key value; do
    STATE[$key]=$value
done < "$STATE_FILE"

VPC_ID=${STATE[VPC]:-}
SUBNET_ID=${STATE[Subnet]:-}
IGW_ID=${STATE[IGW]:-}
ROUTE_TABLE_ID=${STATE[RouteTable]:-}
SECURITY_GROUP_ID=${STATE[SG]:-}
LOAD_BALANCER_ARN=${STATE[LB]:-}
TARGET_GROUP_ARN=${STATE[TG]:-}
NAME=${STATE[NAME]:-k8s-cluster-from-ground-up}
KEY_PATH="ssh/$NAME.pem"

# -----------------------------
# Helper function
# -----------------------------
delete_resource() {
    local desc="$1"
    local cmd="$2"
    echo "Deleting $desc..."
    if ! eval "$cmd"; then
        echo "$desc not found or already deleted, skipping."
    else
        echo "$desc deleted."
    fi
}

# -----------------------------
# 1️⃣ Terminate EC2 instances
# -----------------------------
echo "Terminating EC2 instances..."
INSTANCE_IDS=$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=$NAME*" \
    --query "Reservations[].Instances[].InstanceId" \
    --output text)

if [ -n "$INSTANCE_IDS" ]; then
    aws ec2 terminate-instances --instance-ids $INSTANCE_IDS
    echo "Waiting for instances to terminate..."
    aws ec2 wait instance-terminated --instance-ids $INSTANCE_IDS
    echo "All instances terminated."
else
    echo "No EC2 instances found."
fi

# -----------------------------
# 2️⃣ Delete Load Balancer
# -----------------------------
if [ -n "$LOAD_BALANCER_ARN" ]; then
    delete_resource "Load Balancer" "aws elbv2 delete-load-balancer --load-balancer-arn $LOAD_BALANCER_ARN && aws elbv2 wait load-balancers-deleted --load-balancer-arns $LOAD_BALANCER_ARN"
fi

# -----------------------------
# 3️⃣ Delete Target Group
# -----------------------------
if [ -n "$TARGET_GROUP_ARN" ]; then
    delete_resource "Target Group" "aws elbv2 delete-target-group --target-group-arn $TARGET_GROUP_ARN"
fi

# -----------------------------
# 4️⃣ Delete Security Group
# -----------------------------
if [ -n "$SECURITY_GROUP_ID" ]; then
    delete_resource "Security Group" "aws ec2 delete-security-group --group-id $SECURITY_GROUP_ID"
fi

# -----------------------------
# 5️⃣ Disassociate and delete Route Table
# -----------------------------
if [ -n "$ROUTE_TABLE_ID" ]; then
    echo "Disassociating Route Table..."
    ASSOCIATION_IDS=$(aws ec2 describe-route-tables \
        --route-table-ids $ROUTE_TABLE_ID \
        --query "RouteTables[0].Associations[?RouteTableAssociationId != null].RouteTableAssociationId" \
        --output text)
    if [ -n "$ASSOCIATION_IDS" ]; then
        for assoc in $ASSOCIATION_IDS; do
            aws ec2 disassociate-route-table --association-id $assoc || true
        done
        echo "Route Table disassociated."
    fi
    delete_resource "Route Table" "aws ec2 delete-route-table --route-table-id $ROUTE_TABLE_ID"
fi

# -----------------------------
# 6️⃣ Detach & delete Internet Gateway
# -----------------------------
if [ -n "$IGW_ID" ] && [ -n "$VPC_ID" ]; then
    delete_resource "Internet Gateway" "aws ec2 detach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $VPC_ID && aws ec2 delete-internet-gateway --internet-gateway-id $IGW_ID"
fi

# -----------------------------
# 7️⃣ Delete Subnet
# -----------------------------
if [ -n "$SUBNET_ID" ]; then
    delete_resource "Subnet" "aws ec2 delete-subnet --subnet-id $SUBNET_ID"
fi

# -----------------------------
# 8️⃣ Delete VPC
# -----------------------------
if [ -n "$VPC_ID" ]; then
    delete_resource "VPC" "aws ec2 delete-vpc --vpc-id $VPC_ID"
fi

# -----------------------------
# 9️⃣ Delete SSH keys
# -----------------------------
if [ -f "$KEY_PATH" ]; then
    echo "Deleting local SSH key..."
    rm -f "$KEY_PATH"
    echo "Local SSH key deleted."
fi

aws ec2 delete-key-pair --key-name $NAME || echo "AWS key-pair not found, skipping."
echo "AWS key-pair deletion attempted."

# -----------------------------
# 10️⃣ Remove state file
# -----------------------------
rm -f "$STATE_FILE"
echo "State file removed."

echo "=== Kubernetes infrastructure cleanup complete ==="
