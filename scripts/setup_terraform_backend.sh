#!/bin/bash

# Setup Terraform Backend with S3 and DynamoDB
# This script creates the necessary AWS resources for remote state management

set -e

# Configuration
PROJECT_NAME="k8s-learning-project"
AWS_REGION="us-east-1"
S3_BUCKET_NAME="terraform-state-${PROJECT_NAME}"
DYNAMODB_TABLE_NAME="terraform-lock-${PROJECT_NAME}"

echo "🚀 Setting up Terraform backend infrastructure..."

# Create S3 bucket for Terraform state
echo "📦 Creating S3 bucket: ${S3_BUCKET_NAME}"

# Note: us-east-1 doesn't require LocationConstraint parameter
if [ "${AWS_REGION}" == "us-east-1" ]; then
    aws s3api create-bucket \
        --bucket ${S3_BUCKET_NAME} \
        --region ${AWS_REGION} \
        2>/dev/null || echo "ℹ️  Bucket already exists"
else
    aws s3api create-bucket \
        --bucket ${S3_BUCKET_NAME} \
        --region ${AWS_REGION} \
        --create-bucket-configuration LocationConstraint=${AWS_REGION} \
        2>/dev/null || echo "ℹ️  Bucket already exists"
fi

# Wait a moment for bucket to be fully available
sleep 2

# Enable versioning on the bucket
echo "🔄 Enabling versioning on S3 bucket..."
aws s3api put-bucket-versioning \
    --bucket ${S3_BUCKET_NAME} \
    --versioning-configuration Status=Enabled \
    --region ${AWS_REGION}

# Enable encryption
echo "🔐 Enabling encryption on S3 bucket..."
aws s3api put-bucket-encryption \
    --bucket ${S3_BUCKET_NAME} \
    --region ${AWS_REGION} \
    --server-side-encryption-configuration '{
        "Rules": [{
            "ApplyServerSideEncryptionByDefault": {
                "SSEAlgorithm": "AES256"
            }
        }]
    }'

# Block public access
echo "🚫 Blocking public access to S3 bucket..."
aws s3api put-public-access-block \
    --bucket ${S3_BUCKET_NAME} \
    --region ${AWS_REGION} \
    --public-access-block-configuration \
        BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

# Create DynamoDB table for state locking
echo "🔒 Creating DynamoDB table: ${DYNAMODB_TABLE_NAME}"
aws dynamodb create-table \
    --table-name ${DYNAMODB_TABLE_NAME} \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --provisioned-throughput ReadCapacityUnits=5,WriteCapacityUnits=5 \
    --region ${AWS_REGION} \
    2>/dev/null || echo "ℹ️  DynamoDB table already exists"

# Wait for table to be active
echo "⏳ Waiting for DynamoDB table to be active..."
aws dynamodb wait table-exists \
    --table-name ${DYNAMODB_TABLE_NAME} \
    --region ${AWS_REGION}

echo ""
echo "✅ Terraform backend setup complete!"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📝 Backend Configuration for Terraform:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "terraform {"
echo "  backend \"s3\" {"
echo "    bucket         = \"${S3_BUCKET_NAME}\""
echo "    key            = \"terraform.tfstate\""
echo "    region         = \"${AWS_REGION}\""
echo "    dynamodb_table = \"${DYNAMODB_TABLE_NAME}\""
echo "    encrypt        = true"
echo "  }"
echo "}"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"