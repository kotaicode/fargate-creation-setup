#!/bin/bash

###############
#
# CONFIG
#
###############

AWS_ID=630394441504

APPLICATION_NAME=gattaca
CLUSTER_NAME=gattaca

# create a dedicated VPC with private and public subnets as in: https://docs.aws.amazon.com/AmazonECS/latest/developerguide/create-public-private-vpc.html
VPC_ID=vpc-07ae7c96be5864174

PUBLIC_SUBNET_1_ID=subnet-059104a34cdc3272b
PUBLIC_SUBNET_2_ID=subnet-05a08acf089c9b7b0
PRIVATE_SUBNET_1_ID=subnet-04351a7d979611951
PRIVATE_SUBNET_2_ID=subnet-0364653c4db27ae96

# generate the SG using aws ec2 create-security-group --description allow-http --group-name allow-http --vpc-id ${VPC_ID}
# then add the security group rules to allow access on port 80 and 443 depending on how you expose your loadbalancer
ALB_SECURITY_GROUP_ID=sg-07c21f84ea73964f4

# the same for your ECS service, it is recommended to have a separate SG for it, which opens the connection to the container port
ECS_SECURITY_GROUP_ID=sg-0a8d728362bb52ef8

CONTAINER_CPU=1024
CONTAINER_RAM=2048
CONTAINER_PORT=8080

DOCKER_IMAGE_URL=630394441504.dkr.ecr.eu-central-1.amazonaws.com/gattaca:e864825d496a108bc39fbf75e1b6d1d68c604e79

#############
#
# RESOURCE CREATION
#
#############

# create the ECS cluster
aws ecs create-cluster --cluster-name ${CLUSTER_NAME}


# create the task defintion to define which image to run, where (Fargate), and with which ports exposed
cat > task_definition.json << EOF
{
    "family": "${APPLICATION_NAME}",
    "networkMode": "awsvpc",
    "requiresCompatibilities": [
        "FARGATE"
    ],
    "cpu": "${CONTAINER_CPU}",
    "memory": "${CONTAINER_RAM}",
    "containerDefinitions": [
        {
            "name": "${APPLICATION_NAME}",
            "image": "${DOCKER_IMAGE_URL}",
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
                "secretOptions": null,
                "options": {
                    "awslogs-group": "/ecs/${APPLICATION_NAME}",
                    "awslogs-region": "eu-central-1",
                    "awslogs-stream-prefix": "ecs-${APPLICATION_NAME}"
                }
            }
        }
    ]
}
EOF

aws ecs register-task-definition --cli-input-json file://"$(pwd)"/task_definition.json

# create the target group for the loadbalancer,
# registration of actual targets is then done by ECS
aws elbv2 create-target-group --name ecs-${APPLICATION_NAME}-tg --protocol HTTP --port ${CONTAINER_PORT} --vpc-id ${VPC_ID} --target-type ip
ALB_TG_ARN=$(aws elbv2 describe-target-groups --names ecs-gattaca-service-private|jq -r '.TargetGroups[].TargetGroupArn')

# create ALB (internet facing, with HTTP listener)
# technically one could now also just get all the public subnets from the vpc id... but skipping here
aws elbv2 create-load-balancer --name ${APPLICATION_NAME}-alb --subnets ${PUBLIC_SUBNET_1_ID} ${PUBLIC_SUBNET_2_ID} --security-groups ${ALB_SECURITY_GROUP_ID} --scheme internet-facing
ALB_ARN=$(aws elbv2 describe-load-balancers --names gattaca-service-2 | jq -r '.LoadBalancers[].LoadBalancerArn')
ALB_DNS=$(aws elbv2 describe-load-balancers --names gattaca-service-2 | jq -r '.LoadBalancers[].DNSName')

# create the listener and associate target group with LB
# here we assume that we use HTTP on the LB, not HTTPS
aws elbv2 create-listener --load-balancer-arn ${ALB_ARN} --protocol HTTP --port 80 --default-actions Type=forward,TargetGroupArn=${ALB_TG_ARN}

# create the ECS service and connect it to the created target group
# this takes care of registering the then running containers from the task to the target group
cat > service.json << EOF
{
    "serviceName": "${APPLICATION_NAME}",
    "taskDefinition": "${APPLICATION_NAME}:1",
    "loadBalancers": [
        {
            "targetGroupArn": "${ALB_TG_ARN}",
            "containerName": "${APPLICATION_NAME}",
            "containerPort": ${CONTAINER_PORT}
        }
    ],
    "networkConfiguration": {
        "awsvpcConfiguration": {
            "assignPublicIp": "ENABLED",
            "securityGroups": ["${ECS_SECURITY_GROUP_ID}"],
            "subnets": ["${PRIVATE_SUBNET_1_ID}", "${PRIVATE_SUBNET_2_ID}"]
        }
    },
    "desiredCount": 2,
    "launchType": "FARGATE"
}
EOF
aws ecs create-service --cluster ${CLUSTER_NAME} --service-name ${APPLICATION_NAME}-service --cli-input-json file://"$(pwd)"/service.json

echo "application ready at DNS: ${ALB_DNS}" 
