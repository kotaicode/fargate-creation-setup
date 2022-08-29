#!/bin/bash

# https://stackoverflow.com/a/2871034 👇
set -euxo pipefail


[ $# -eq 6 ] || echo "Usage: $0 AWSID CLUSTERNAME APPLICATIONNAME PORT CERTIFICATENAME TASKSNUMBER"
[ $# -eq 6 ] || exit 1

jq --help > /dev/null || echo "You need to install jq to run this script"
jq --help > /dev/null || exit 1

###############
#
# CONFIG
#
###############

# TODO AWSID and PORT must be numbers, and PORT is < 65536 (add
# validations in future)
AWS_ID=$1
CLUSTER_NAME=$2
APPLICATION_NAME=$3
APPLICATIONPORT=$4
CERTIFICATE_NAME=$5
TASKS_NUMBER=$6

VPC_NAME=ecs-cluster-${CLUSTER_NAME}

INTERNET_GATEWAY_NAME=${VPC_NAME}

ALB_SECURITY_GROUP_NAME=${VPC_NAME}-alb-sg
ECS_SECURITY_GROUP_NAME=${VPC_NAME}-ecs-sg

WAIT_FOR_NAT_CREATION=""

#############################
# GET DETAILS OF THE CLUSTER
#############################

VPC_ID=$(aws ec2 describe-vpcs --filters Name=tag:Name,Values=${VPC_NAME} --query Vpcs[0].VpcId --output text)

# If vpc id is missing, we should just create everything anyway.
if [[ "${VPC_ID}" == *"None"* ]]; then

    VPC_ID=$(aws ec2 create-vpc --cidr-block 172.32.0.0/16 --instance-tenancy default --tag-specification "ResourceType=vpc,Tags=[{Key=Name,Value=${VPC_NAME}}]" --query Vpc.VpcId --output text)
    aws ec2 modify-vpc-attribute --vpc-id ${VPC_ID} --enable-dns-support "{\"Value\":true}"

    INTERNET_GATEWAY_ID=$(aws ec2 create-internet-gateway --tag-specification "ResourceType=internet-gateway,Tags=[{Key=Name,Value=${VPC_NAME}}]" --query InternetGateway.InternetGatewayId --output text)
    aws ec2 attach-internet-gateway --vpc-id ${VPC_ID} --internet-gateway-id ${INTERNET_GATEWAY_ID}

    ROUTE_TABLE_ID=$(aws ec2 create-route-table --vpc-id ${VPC_ID} --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=${VPC_NAME}}]" --query RouteTable.RouteTableId --output text)
    aws ec2 create-route --route-table-id ${ROUTE_TABLE_ID} --destination-cidr-block 0.0.0.0/0 --gateway-id ${INTERNET_GATEWAY_ID}

    PRIVATE_SUBNET_1_ID=$(aws ec2 create-subnet --vpc-id ${VPC_ID} --cidr-block 172.32.0.0/20 --availability-zone eu-central-1a --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${VPC_NAME}-private}]" --query Subnet.SubnetId --output text)
    PRIVATE_SUBNET_2_ID=$(aws ec2 create-subnet --vpc-id ${VPC_ID} --cidr-block 172.32.16.0/20 --availability-zone eu-central-1b --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${VPC_NAME}-private}]" --query Subnet.SubnetId --output text)

    PUBLIC_SUBNET_1_ID=$(aws ec2 create-subnet --vpc-id ${VPC_ID} --cidr-block 172.32.32.0/20 --availability-zone eu-central-1a --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${VPC_NAME}-public}]" --query Subnet.SubnetId --output text)
    aws ec2 associate-route-table --subnet-id ${PUBLIC_SUBNET_1_ID} --route-table-id ${ROUTE_TABLE_ID}
    aws ec2 modify-subnet-attribute --subnet-id ${PUBLIC_SUBNET_1_ID} --map-public-ip-on-launch

    PUBLIC_SUBNET_2_ID=$(aws ec2 create-subnet --vpc-id ${VPC_ID} --cidr-block 172.32.48.0/20 --availability-zone eu-central-1b --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${VPC_NAME}-public}]" --query Subnet.SubnetId --output text)
    aws ec2 associate-route-table --subnet-id ${PUBLIC_SUBNET_2_ID} --route-table-id ${ROUTE_TABLE_ID}
    aws ec2 modify-subnet-attribute --subnet-id ${PUBLIC_SUBNET_2_ID} --map-public-ip-on-launch

    MAIN_VPC_ROUTE_TABLE=$(aws ec2 describe-route-tables --filters Name=vpc-id,Values=${VPC_ID} Name=association.main,Values=true --query "RouteTables[0].RouteTableId" --output text)
    aws ec2 associate-route-table --route-table-id ${MAIN_VPC_ROUTE_TABLE} --subnet-id ${PRIVATE_SUBNET_1_ID}
    aws ec2 associate-route-table --route-table-id ${MAIN_VPC_ROUTE_TABLE} --subnet-id ${PRIVATE_SUBNET_2_ID}
    ELASTIC_IP_1=$(aws ec2 allocate-address --query AllocationId --output text)
    NAT_ID_1=$(aws ec2 create-nat-gateway --subnet-id ${PUBLIC_SUBNET_1_ID} --allocation-id ${ELASTIC_IP_1} --tag-specifications "ResourceType=natgateway,Tags=[{Key=Name,Value=${VPC_NAME}}]" --query NatGateway.NatGatewayId --output text)
    # This command wont work till nat gateway is completely created
    WAIT_FOR_NAT_CREATION="aws ec2 create-route --route-table-id ${MAIN_VPC_ROUTE_TABLE} --destination-cidr-block 0.0.0.0/0 --nat-gateway-id ${NAT_ID_1}"
    #TODO Wait while NAT_STATE is pending. We want available.
    #NAT_STATE=$(aws ec2 describe-nat-gateways --query "NatGateways[?NatGatewayId=='nat-04fde583db9ad1f68'].State | [0]" --output text)

    ALB_SECURITY_GROUP_ID=$(aws ec2 create-security-group --description allow-http --group-name ${ALB_SECURITY_GROUP_NAME} --vpc-id ${VPC_ID} --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=${VPC_NAME}-alb-sg}]" --query GroupId  --output text)
    aws ec2 authorize-security-group-ingress --group-id ${ALB_SECURITY_GROUP_ID} --protocol tcp --port 80 --cidr 0.0.0.0/0
    aws ec2 authorize-security-group-ingress --group-id ${ALB_SECURITY_GROUP_ID} --protocol tcp --port 443 --cidr 0.0.0.0/0

    ECS_SECURITY_GROUP_ID=$(aws ec2 create-security-group --description allow-http --group-name ${ECS_SECURITY_GROUP_NAME} --vpc-id ${VPC_ID} --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=${VPC_NAME}-ecs-sg}]" --query GroupId --output text)
    aws ec2 authorize-security-group-ingress  --group-id  ${ECS_SECURITY_GROUP_ID} --protocol tcp --port 0-65535  --source-group ${ALB_SECURITY_GROUP_ID}

    aws ecs create-cluster --cluster-name ${CLUSTER_NAME}

fi

# Let's read them all nicely (should we try to read and create if fail for EVERY item?)
ALB_SECURITY_GROUP_ID=$(aws ec2 describe-security-groups --query "SecurityGroups[?GroupName=='${ALB_SECURITY_GROUP_NAME}'].GroupId | [0]" --output text)
ECS_SECURITY_GROUP_ID=$(aws ec2 describe-security-groups --query "SecurityGroups[?GroupName=='${ECS_SECURITY_GROUP_NAME}'].GroupId | [0]" --output text)

PRIVATE_SUBNET_1_ID=$(aws ec2 describe-subnets --filters Name=vpc-id,Values=${VPC_ID} Name=cidr-block,Values=172.32.0.0/20 --query "Subnets[0].SubnetId" --output text)
PRIVATE_SUBNET_2_ID=$(aws ec2 describe-subnets --filters Name=vpc-id,Values=${VPC_ID} Name=cidr-block,Values=172.32.16.0/20 --query "Subnets[0].SubnetId" --output text)

PUBLIC_SUBNET_1_ID=$(aws ec2 describe-subnets --filters Name=vpc-id,Values=${VPC_ID} Name=cidr-block,Values=172.32.32.0/20 --query "Subnets[0].SubnetId" --output text)
PUBLIC_SUBNET_2_ID=$(aws ec2 describe-subnets --filters Name=vpc-id,Values=${VPC_ID} Name=cidr-block,Values=172.32.48.0/20 --query "Subnets[0].SubnetId" --output text)

INTERNET_GATEWAY_ID=$(aws ec2 describe-internet-gateways --filters Name=tag:Name,Values=${INTERNET_GATEWAY_NAME} --query InternetGateways[0].InternetGatewayId --output text)

CERTIFICATE_ARN=$(aws iam list-server-certificates --query "ServerCertificateMetadataList[?ServerCertificateName=='${CERTIFICATE_NAME}'].Arn | [0]" --output text)

ROLEMUSTBECREATED=
aws iam list-roles | grep ecsTaskExecutionRole || ROLEMUSTBECREATED="true"
if [ ! -z ${ROLEMUSTBECREATED} ]; then
    cat > ecs-role-definition.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "",
      "Effect": "Allow",
      "Principal": {
        "Service": "ecs-tasks.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
    aws iam --region us-west-2 create-role --role-name ecsTaskExecutionRole --assume-role-policy-document file://ecs-role-definition.json
    aws iam --region us-west-2 attach-role-policy --role-name ecsTaskExecutionRole --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy
fi

ECS_TASK_EXECUTION_ROLE_ARN=$(aws iam get-role --role-name ecsTaskExecutionRole --query "Role.Arn" --output text)

VARMISSING=
[ -z $ALB_SECURITY_GROUP_ID ]           && echo "ALB_SECURITY_GROUP_ID is empty " && VARMISSING="true"
[ -z $ECS_SECURITY_GROUP_ID ]           && echo "ECS_SECURITY_GROUP_ID is empty " && VARMISSING="true"
[ -z $PRIVATE_SUBNET_1_ID ]             && echo "PRIVATE_SUBNET_1_ID is empty   " && VARMISSING="true"
[ -z $PRIVATE_SUBNET_2_ID ]             && echo "PRIVATE_SUBNET_2_ID is empty   " && VARMISSING="true"
[ -z $PUBLIC_SUBNET_1_ID ]              && echo "PUBLIC_SUBNET_1_ID is empty    " && VARMISSING="true"
[ -z $PUBLIC_SUBNET_2_ID ]              && echo "PUBLIC_SUBNET_2_ID is empty    " && VARMISSING="true"
[ -z $ECS_TASK_EXECUTION_ROLE_ARN ]     && echo "ECS_TASK_EXECUTION_ROLE_ARN is empty    " && VARMISSING="true"
[ -z $VARMISSING ] || exit 1



#############
#
# RESOURCE CREATION
#
#############

# create log group
aws logs create-log-group --log-group-name "/ecs/${APPLICATION_NAME}-${CLUSTER_NAME}"
aws logs put-retention-policy --log-group-name "/ecs/${APPLICATION_NAME}-${CLUSTER_NAME}" --retention-in-days 7
aws ecr create-repository --repository-name ${APPLICATION_NAME}-${CLUSTER_NAME}

DOCKER_IMAGE_URL=${AWS_ID}.dkr.ecr.eu-central-1.amazonaws.com/${APPLICATION_NAME}-${CLUSTER_NAME}:latest

AWS_REGION=${AWS_REGION:-"eu-central-1"}
CONTAINER_CPU=1024
CONTAINER_CPU_HARD=512
CONTAINER_RAM=2048
CONTAINER_RAM_HARD=1024
CONTAINER_PORT=${APPLICATIONPORT}

# create the task definition to define which image to run, where (Fargate), and with which ports exposed
cat > task-definition.json << EOF
{
    "family": "${APPLICATION_NAME}-${CLUSTER_NAME}",
    "executionRoleArn": "${ECS_TASK_EXECUTION_ROLE_ARN}",
    "networkMode": "awsvpc",
    "requiresCompatibilities": [
        "FARGATE"
    ],
    "cpu": "${CONTAINER_CPU}",
    "memory": "${CONTAINER_RAM}",
    "containerDefinitions": [
        {
            "name": "${APPLICATION_NAME}-${CLUSTER_NAME}",
            "image": "${DOCKER_IMAGE_URL}",
            "cpu": ${CONTAINER_CPU_HARD},
            "memory": ${CONTAINER_RAM_HARD},
            "portMappings": [
                {
                    "containerPort": ${CONTAINER_PORT},
                    "hostPort": ${CONTAINER_PORT},
                    "protocol": "tcp"
                }
            ],
            "essential": true,
            "logConfiguration": {
                "logDriver": "awslogs",
                "options": {
                    "awslogs-group": "/ecs/${APPLICATION_NAME}-${CLUSTER_NAME}",
                    "awslogs-region": "${AWS_REGION}",
                    "awslogs-stream-prefix": "ecs-${APPLICATION_NAME}-${CLUSTER_NAME}"
                }
            }
        }
    ]
}
EOF

TASK_REVISION_NUMBER=$(aws ecs register-task-definition --cli-input-json file://"$(pwd)"/task-definition.json --query "taskDefinition.revision" --output text)

# create the target group for the loadbalancer,
# registration of actual targets is then done by ECS
aws elbv2 create-target-group --name ecs-${APPLICATION_NAME}-${CLUSTER_NAME}-tg --protocol HTTP --port ${CONTAINER_PORT} --vpc-id ${VPC_ID} --target-type ip
ALB_TG_ARN=$(aws elbv2 describe-target-groups --names ecs-${APPLICATION_NAME}-${CLUSTER_NAME}-tg | jq -r '.TargetGroups[].TargetGroupArn')

# create ALB (internet facing, with HTTP listener)
aws elbv2 create-load-balancer --name ${APPLICATION_NAME}-${CLUSTER_NAME}-alb --subnets ${PUBLIC_SUBNET_1_ID} ${PUBLIC_SUBNET_2_ID} --security-groups ${ALB_SECURITY_GROUP_ID} --scheme internet-facing
ALB_ARN=$(aws elbv2 describe-load-balancers --names ${APPLICATION_NAME}-${CLUSTER_NAME}-alb | jq -r '.LoadBalancers[].LoadBalancerArn')
ALB_DNS=$(aws elbv2 describe-load-balancers --names ${APPLICATION_NAME}-${CLUSTER_NAME}-alb | jq -r '.LoadBalancers[].DNSName')

# create the listener and associate target group with LB
aws elbv2 create-listener --load-balancer-arn ${ALB_ARN} --protocol HTTPS --port 443 --certificates CertificateArn=$CERTIFICATE_ARN --ssl-policy ELBSecurityPolicy-2016-08 --default-actions Type=forward,TargetGroupArn=${ALB_TG_ARN}
# create the ECS service and connect it to the created target group
# this takes care of registering the then running containers from the task to the target group
cat > service.json << EOF
{
    "serviceName": "${APPLICATION_NAME}-${CLUSTER_NAME}",
    "taskDefinition": "${APPLICATION_NAME}-${CLUSTER_NAME}:${TASK_REVISION_NUMBER}",
    "loadBalancers": [
        {
            "targetGroupArn": "${ALB_TG_ARN}",
            "containerName": "${APPLICATION_NAME}-${CLUSTER_NAME}",
            "containerPort": ${CONTAINER_PORT}
        }
    ],
    "networkConfiguration": {
        "awsvpcConfiguration": {
            "assignPublicIp": "DISABLED",
            "securityGroups": ["${ECS_SECURITY_GROUP_ID}"],
            "subnets": ["${PRIVATE_SUBNET_1_ID}", "${PRIVATE_SUBNET_2_ID}"]
        }
    },
    "desiredCount": ${TASKS_NUMBER},
    "launchType": "FARGATE"
}
EOF

aws ecs create-service --cluster ${CLUSTER_NAME} --service-name ${APPLICATION_NAME}-${CLUSTER_NAME}-service --cli-input-json file://"$(pwd)"/service.json
echo  "run it manually after nat creation > : ${WAIT_FOR_NAT_CREATION}"
echo "application ready at DNS: ${ALB_DNS}"
