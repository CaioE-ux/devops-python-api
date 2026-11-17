#!/usr/bin/env bash
# Provisiona a infraestrutura AWS do projeto (executar no AWS CloudShell, região us-east-1).
# Cria: repositório ECR, provedor OIDC do GitHub, role do GitHub Actions,
# role/instance profile da EC2, key pair, security group, instância EC2 e Elastic IP.
set -euo pipefail

REGION=us-east-1
GITHUB_REPO=CaioE-ux/devops-python-api
APP=devops-python-api
GH_ROLE=github-actions-$APP
EC2_ROLE=ec2-ecr-readonly
KEY_NAME=github-actions-deploy
DEPLOY_PUBLIC_KEY="ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQCgYKjer6XLo17642STjT9daP9BssBwonPHK7sPkWULKl+limLUba/q/uos2+NoCCmFPHM20oAWnibK7mxvtkEjPOI0RTCOf20IOg2aCDQWPVGPWjHRkpodK6L383V7hYB3aUjWorVk5V5TOlYhYiO2M6QEz7dggLtk+X6uB3t79EvorK3WdWVGJNxt6rj5XrbvNPEoc3VFRy2cntzEBnZ9n3Pt9+z2KbeN7qR8U023iQYNCsWmJ+s5uu420l9yrP2CZ4+EX/PrGdafmDmru8tyaq2AfCew+pPMeWRBocYs0UDbj8NM8C3gd8zA2cHujsUIix9GeBMKsRt9wN35OTnI3WxHErkp6Dzbf6kfw2G0uHfyMkZr1gdZHws/54XlGB5ydIW4QgHGQPKNpJ/R7g6cJTuShCsvG1LxA695Bm7tx1LCvwCFp+kF3EWWhO5JE2jNAg29VwEPzntSfHH1L1dE3qE9XaolxnGJ2FM627vQxsD/2e7i47fEqpNh0vjodXr+ncX0LN41xxjoSzp1reEEA9b4D82PI976d9oQsiZX+zqczwfMzuEyO/3x8V+6qOWHE3kRVJj7Rv8UG0Jb829VdehL+fgO8Cn/cxbl7ioqL34vHX1iop0u/N15fge3gKNsLgBg8/JTH46Aq97nHd/WahMBIvkmB3K5DYD/rWU+kQ== github-actions-deploy"

export AWS_DEFAULT_REGION=$REGION
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
TMP=$(mktemp -d)
echo ">> Conta $ACCOUNT_ID, região $REGION"

echo ">> 1/8 Repositório privado no ECR"
aws ecr describe-repositories --repository-names $APP >/dev/null 2>&1 || \
  aws ecr create-repository --repository-name $APP \
    --image-scanning-configuration scanOnPush=true >/dev/null

echo ">> 2/8 Provedor OIDC do GitHub Actions"
OIDC_ARN=arn:aws:iam::$ACCOUNT_ID:oidc-provider/token.actions.githubusercontent.com
aws iam get-open-id-connect-provider --open-id-connect-provider-arn $OIDC_ARN >/dev/null 2>&1 || \
  aws iam create-open-id-connect-provider \
    --url https://token.actions.githubusercontent.com \
    --client-id-list sts.amazonaws.com \
    --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1 >/dev/null

echo ">> 3/8 Role do GitHub Actions (somente a main deste repositório pode assumir)"
cat > $TMP/trust.json <<JSON
{"Version":"2012-10-17","Statement":[{"Effect":"Allow",
 "Principal":{"Federated":"$OIDC_ARN"},
 "Action":"sts:AssumeRoleWithWebIdentity",
 "Condition":{"StringEquals":{
   "token.actions.githubusercontent.com:aud":"sts.amazonaws.com",
   "token.actions.githubusercontent.com:sub":"repo:$GITHUB_REPO:ref:refs/heads/main"}}}]}
JSON
cat > $TMP/push.json <<JSON
{"Version":"2012-10-17","Statement":[
 {"Effect":"Allow","Action":"ecr:GetAuthorizationToken","Resource":"*"},
 {"Effect":"Allow","Action":["ecr:BatchCheckLayerAvailability","ecr:BatchGetImage",
   "ecr:CompleteLayerUpload","ecr:InitiateLayerUpload","ecr:PutImage","ecr:UploadLayerPart"],
  "Resource":"arn:aws:ecr:$REGION:$ACCOUNT_ID:repository/$APP"}]}
JSON
aws iam get-role --role-name $GH_ROLE >/dev/null 2>&1 || \
  aws iam create-role --role-name $GH_ROLE --assume-role-policy-document file://$TMP/trust.json >/dev/null
aws iam put-role-policy --role-name $GH_ROLE --policy-name ecr-push --policy-document file://$TMP/push.json

echo ">> 4/8 Role da EC2 com leitura do ECR"
aws iam get-role --role-name $EC2_ROLE >/dev/null 2>&1 || \
  aws iam create-role --role-name $EC2_ROLE --assume-role-policy-document \
    '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
aws iam attach-role-policy --role-name $EC2_ROLE \
  --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly
if ! aws iam get-instance-profile --instance-profile-name $EC2_ROLE >/dev/null 2>&1; then
  aws iam create-instance-profile --instance-profile-name $EC2_ROLE >/dev/null
  aws iam add-role-to-instance-profile --instance-profile-name $EC2_ROLE --role-name $EC2_ROLE
  sleep 15 # propagação do instance profile
fi

echo ">> 5/8 Key pair (chave pública usada pelo deploy)"
aws ec2 describe-key-pairs --key-names $KEY_NAME >/dev/null 2>&1 || \
  aws ec2 import-key-pair --key-name $KEY_NAME \
    --public-key-material "$(echo -n "$DEPLOY_PUBLIC_KEY" | base64 -w0)" >/dev/null

echo ">> 6/8 Security group (22 para o deploy, 80 para a API)"
VPC=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)
SG=$(aws ec2 describe-security-groups --filters Name=group-name,Values=$APP-sg Name=vpc-id,Values=$VPC \
  --query 'SecurityGroups[0].GroupId' --output text)
if [ "$SG" = "None" ]; then
  SG=$(aws ec2 create-security-group --group-name $APP-sg --description "SSH (deploy) e HTTP (API)" \
    --vpc-id $VPC --query GroupId --output text)
  aws ec2 authorize-security-group-ingress --group-id $SG --protocol tcp --port 22 --cidr 0.0.0.0/0 >/dev/null
  aws ec2 authorize-security-group-ingress --group-id $SG --protocol tcp --port 80 --cidr 0.0.0.0/0 >/dev/null
fi

echo ">> 7/8 Instância EC2 (Amazon Linux 2023 + Docker via user data)"
IID=$(aws ec2 describe-instances --filters Name=tag:Name,Values=$APP Name=instance-state-name,Values=pending,running \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)
if [ "$IID" = "None" ]; then
  AMI=$(aws ssm get-parameter --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
    --query Parameter.Value --output text)
  cat > $TMP/user-data.sh <<'UD'
#!/bin/bash
dnf update -y
dnf install -y docker
systemctl enable --now docker
usermod -aG docker ec2-user
UD
  IID=$(aws ec2 run-instances --image-id $AMI --instance-type t3.micro --key-name $KEY_NAME \
    --security-group-ids $SG --iam-instance-profile Name=$EC2_ROLE \
    --user-data file://$TMP/user-data.sh \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$APP}]" \
    --query 'Instances[0].InstanceId' --output text)
fi
aws ec2 wait instance-running --instance-ids $IID

echo ">> 8/8 Elastic IP"
EIP=$(aws ec2 describe-addresses --filters Name=instance-id,Values=$IID --query 'Addresses[0].PublicIp' --output text)
if [ "$EIP" = "None" ]; then
  ALLOC=$(aws ec2 allocate-address --domain vpc --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=$APP}]" \
    --query AllocationId --output text)
  aws ec2 associate-address --instance-id $IID --allocation-id $ALLOC >/dev/null
  EIP=$(aws ec2 describe-addresses --allocation-ids $ALLOC --query 'Addresses[0].PublicIp' --output text)
fi

echo
echo "================ CONFIGURAR NO GITHUB ================"
echo "Secret   AWS_ROLE_ARN = arn:aws:iam::$ACCOUNT_ID:role/$GH_ROLE"
echo "Variable EC2_HOST     = $EIP"
echo "Variable EC2_USER     = ec2-user"
echo "Instância: $IID"
echo "RESULTADO_OK $ACCOUNT_ID $EIP $IID"
