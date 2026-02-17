#!/bin/bash
# ── Wrapper entrypoint: starts LocalStack, waits, provisions resources ──
export AWS_PAGER=""

# Start the real LocalStack entrypoint in the background
docker-entrypoint.sh &
LOCALSTACK_PID=$!

echo "============================================"
echo "  Waiting for LocalStack to be ready..."
echo "============================================"

# Wait for health endpoint (up to 120 seconds)
ENDPOINT="http://127.0.0.1:4566"
for i in $(seq 1 120); do
    if curl -sf "${ENDPOINT}/_localstack/health" | grep -q '"s3"'; then
        echo "  ✅ LocalStack is ready (attempt $i)"
        break
    fi
    if ! kill -0 $LOCALSTACK_PID 2>/dev/null; then
        echo "  ❌ LocalStack process died!"
        exit 1
    fi
    sleep 1
done

# Extra wait for services to fully initialize
sleep 3

# ── Run provisioning inline ──
echo ""
echo "============================================"
echo "  Provisioning AWS resources..."
echo "============================================"

AWS="awslocal --region us-east-1"

UPLOAD_BUCKET="pdf-uploads"
OUTPUT_BUCKET="pdf-text-output"
UPLOAD_QUEUE="upload-notifications"
RESULT_QUEUE="processing-results"
LAMBDA_NAME="pdf-processor"

# ── 1. S3 Buckets ──
echo "-> Creating S3 buckets..."
$AWS s3 mb s3://$UPLOAD_BUCKET
$AWS s3 mb s3://$OUTPUT_BUCKET
echo "  Buckets:"
$AWS s3 ls

# ── 2. S3 CORS ──
echo "-> Configuring S3 CORS..."
for BUCKET in $UPLOAD_BUCKET $OUTPUT_BUCKET; do
    $AWS s3api put-bucket-cors --bucket $BUCKET --cors-configuration '{
        "CORSRules": [{
            "AllowedOrigins": ["*"],
            "AllowedMethods": ["GET","PUT","POST","DELETE","HEAD"],
            "AllowedHeaders": ["*"],
            "ExposeHeaders": ["ETag","x-amz-request-id","Content-Length","Content-Type"],
            "MaxAgeSeconds": 3600
        }]
    }'
done
echo "  CORS set on both buckets"

# ── 3. SQS Queues ──
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

# SQS policy: allow S3 to send messages
$AWS sqs set-queue-attributes \
    --queue-url "$UPLOAD_QUEUE_URL" \
    --attributes '{"Policy":"{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Principal\":\"*\",\"Action\":\"sqs:SendMessage\",\"Resource\":\"*\"}]}"}'
echo "  SQS policy applied"

# ── 4. S3 -> SQS Event Notification ──
echo "-> Configuring S3 -> SQS notification..."
$AWS s3api put-bucket-notification-configuration \
    --bucket $UPLOAD_BUCKET \
    --notification-configuration '{
        "QueueConfigurations": [{
            "QueueArn": "'"$UPLOAD_QUEUE_ARN"'",
            "Events": ["s3:ObjectCreated:*"],
            "Filter": {
                "Key": {
                    "FilterRules": [{"Name":"suffix","Value":".pdf"}]
                }
            }
        }]
    }'
echo "  S3 event notification configured"

# ── 5. Build Lambda Package ──
echo "-> Building Lambda package..."
BUILD_DIR="/tmp/lambda-build"
rm -rf $BUILD_DIR && mkdir -p $BUILD_DIR

pip install -q -t $BUILD_DIR pypdf==4.1.0 2>/dev/null
cp /opt/lambda/handler.py $BUILD_DIR/

cd $BUILD_DIR && zip -q -r /tmp/lambda.zip .
echo "  Package: $(du -h /tmp/lambda.zip | cut -f1)"

# ── 6. Create Lambda Function ──
echo "-> Creating Lambda function..."
LAMBDA_ENDPOINT="http://localhost.localstack.cloud:4566"

$AWS lambda create-function \
    --function-name $LAMBDA_NAME \
    --runtime python3.11 \
    --handler handler.handler \
    --zip-file fileb:///tmp/lambda.zip \
    --role arn:aws:iam::000000000000:role/lambda-role \
    --timeout 120 \
    --memory-size 512 \
    --environment "Variables={AWS_ENDPOINT_URL=$LAMBDA_ENDPOINT,OUTPUT_BUCKET=$OUTPUT_BUCKET,RESULT_QUEUE_URL=$LAMBDA_ENDPOINT/000000000000/$RESULT_QUEUE,AWS_DEFAULT_REGION=us-east-1}" \
    2>/dev/null || \
$AWS lambda update-function-code \
    --function-name $LAMBDA_NAME \
    --zip-file fileb:///tmp/lambda.zip
echo "  Lambda created"

# ── 7. SQS -> Lambda Trigger ──
echo "-> Creating SQS -> Lambda event source mapping..."
$AWS lambda create-event-source-mapping \
    --function-name $LAMBDA_NAME \
    --event-source-arn "$UPLOAD_QUEUE_ARN" \
    --batch-size 1 \
    --enabled 2>/dev/null || true
echo "  Event source mapping created"

# ── 8. Verify ──
echo ""
echo "============================================"
echo "  ✅ All resources provisioned!"
echo "============================================"
echo "  S3 buckets:"
$AWS s3 ls
echo "  SQS queues:"
$AWS sqs list-queues --query 'QueueUrls' --output text
echo "  Lambda:"
$AWS lambda list-functions --query 'Functions[].FunctionName' --output text
echo "  Mappings:"
$AWS lambda list-event-source-mappings --function-name $LAMBDA_NAME --query 'EventSourceMappings[].State' --output text
echo "============================================"
echo "  Open http://localhost:8080"
echo "============================================"

# ── Keep container alive: wait on LocalStack process ──
wait $LOCALSTACK_PID
