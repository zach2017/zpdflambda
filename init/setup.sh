#!/bin/bash
set -euo pipefail
echo "============================================"
echo "  Initializing LocalStack resources..."
echo "============================================"

REGION="us-east-1"
ENDPOINT="http://localhost:4566"
AWS="aws --endpoint-url=$ENDPOINT --region=$REGION"

UPLOAD_BUCKET="pdf-uploads"
OUTPUT_BUCKET="pdf-text-output"
UPLOAD_QUEUE="upload-notifications"
RESULT_QUEUE="processing-results"
LAMBDA_NAME="pdf-processor"

# ── 1. Create S3 Buckets ──
echo "-> Creating S3 buckets..."
$AWS s3 mb s3://$UPLOAD_BUCKET 2>/dev/null || true
$AWS s3 mb s3://$OUTPUT_BUCKET 2>/dev/null || true

# ── 1b. Configure S3 CORS ──
echo "-> Configuring S3 bucket CORS..."
CORS_CONFIG='{
    "CORSRules": [
        {
            "AllowedOrigins": ["*"],
            "AllowedMethods": ["GET", "PUT", "POST", "DELETE", "HEAD"],
            "AllowedHeaders": ["*"],
            "ExposeHeaders": ["ETag", "x-amz-request-id", "Content-Length", "Content-Type"],
            "MaxAgeSeconds": 3600
        }
    ]
}'
$AWS s3api put-bucket-cors --bucket $UPLOAD_BUCKET --cors-configuration "$CORS_CONFIG"
$AWS s3api put-bucket-cors --bucket $OUTPUT_BUCKET --cors-configuration "$CORS_CONFIG"
echo "  CORS configured on both buckets"

# ── 2. Create SQS Queues ──
echo "-> Creating SQS queues..."
UPLOAD_QUEUE_URL=$($AWS sqs create-queue --queue-name $UPLOAD_QUEUE --query 'QueueUrl' --output text)
RESULT_QUEUE_URL=$($AWS sqs create-queue --queue-name $RESULT_QUEUE --query 'QueueUrl' --output text)
echo "  Upload Queue: $UPLOAD_QUEUE_URL"
echo "  Result Queue: $RESULT_QUEUE_URL"

UPLOAD_QUEUE_ARN=$($AWS sqs get-queue-attributes \
    --queue-url "$UPLOAD_QUEUE_URL" \
    --attribute-names QueueArn \
    --query 'Attributes.QueueArn' --output text)
echo "  Upload Queue ARN: $UPLOAD_QUEUE_ARN"

# Allow S3 to send messages to SQS
$AWS sqs set-queue-attributes \
    --queue-url "$UPLOAD_QUEUE_URL" \
    --attributes '{
        "Policy": "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Principal\":\"*\",\"Action\":\"sqs:SendMessage\",\"Resource\":\"*\"}]}"
    }'

# ── 3. Configure S3 -> SQS Notification ──
echo "-> Configuring S3 event notification..."
$AWS s3api put-bucket-notification-configuration \
    --bucket $UPLOAD_BUCKET \
    --notification-configuration "{
        \"QueueConfigurations\": [{
            \"QueueArn\": \"$UPLOAD_QUEUE_ARN\",
            \"Events\": [\"s3:ObjectCreated:*\"],
            \"Filter\": {
                \"Key\": {
                    \"FilterRules\": [{
                        \"Name\": \"suffix\",
                        \"Value\": \".pdf\"
                    }]
                }
            }
        }]
    }"

# ── 4. Build Lambda Package ──
echo "-> Building Lambda deployment package..."
LAMBDA_DIR="/opt/lambda"
BUILD_DIR="/tmp/lambda-build"
rm -rf $BUILD_DIR
mkdir -p $BUILD_DIR

pip install -q -t $BUILD_DIR pypdf==4.1.0 2>/dev/null
cp $LAMBDA_DIR/handler.py $BUILD_DIR/

cd $BUILD_DIR
zip -q -r /tmp/lambda.zip .
echo "  Package size: $(du -h /tmp/lambda.zip | cut -f1)"

# ── 5. Create Lambda Function ──
echo "-> Creating Lambda function..."

# Detect the right endpoint for Lambda to call back to LocalStack
# In LocalStack 3.x hot-reload mode, Lambda runs inside the container
LAMBDA_ENDPOINT="http://localhost.localstack.cloud:4566"

$AWS lambda create-function \
    --function-name $LAMBDA_NAME \
    --runtime python3.11 \
    --handler handler.handler \
    --zip-file fileb:///tmp/lambda.zip \
    --role arn:aws:iam::000000000000:role/lambda-role \
    --timeout 120 \
    --memory-size 512 \
    --environment "Variables={
        AWS_ENDPOINT_URL=$LAMBDA_ENDPOINT,
        OUTPUT_BUCKET=$OUTPUT_BUCKET,
        RESULT_QUEUE_URL=$RESULT_QUEUE_URL,
        AWS_DEFAULT_REGION=$REGION
    }" 2>/dev/null || \
$AWS lambda update-function-code \
    --function-name $LAMBDA_NAME \
    --zip-file fileb:///tmp/lambda.zip

# ── 6. Create SQS -> Lambda Trigger ──
echo "-> Creating SQS -> Lambda event source mapping..."
$AWS lambda create-event-source-mapping \
    --function-name $LAMBDA_NAME \
    --event-source-arn "$UPLOAD_QUEUE_ARN" \
    --batch-size 1 \
    --enabled 2>/dev/null || true

echo ""
echo "============================================"
echo "  All resources initialized!"
echo "  Upload bucket:  s3://$UPLOAD_BUCKET"
echo "  Output bucket:  s3://$OUTPUT_BUCKET"
echo "  Upload queue:   $UPLOAD_QUEUE"
echo "  Result queue:   $RESULT_QUEUE"
echo "  Lambda:         $LAMBDA_NAME"
echo "============================================"
echo "  Open http://localhost:8080 in your browser"
echo "============================================"
