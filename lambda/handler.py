import json
import os
import boto3
import urllib.parse
from io import BytesIO

# Use pypdf for text extraction
from pypdf import PdfReader

ENDPOINT_URL = os.environ.get("AWS_ENDPOINT_URL", "http://localhost.localstack.cloud:4566")
REGION = os.environ.get("AWS_DEFAULT_REGION", "us-east-1")
OUTPUT_BUCKET = os.environ.get("OUTPUT_BUCKET", "pdf-text-output")
RESULT_QUEUE_NAME = os.environ.get("RESULT_QUEUE_URL", "")  # May contain full URL from init


def get_clients():
    kwargs = {
        "region_name": REGION,
        "endpoint_url": ENDPOINT_URL,
        "aws_access_key_id": "test",
        "aws_secret_access_key": "test",
    }
    s3 = boto3.client("s3", **kwargs)
    sqs = boto3.client("sqs", **kwargs)
    # Rebuild result queue URL using this Lambda's endpoint
    result_queue_url = f"{ENDPOINT_URL}/000000000000/processing-results"
    return s3, sqs, result_queue_url


def handler(event, context):
    s3, sqs, result_queue_url = get_clients()

    for record in event.get("Records", []):
        body = json.loads(record.get("body", "{}"))

        # Handle S3 event notification structure
        for s3_record in body.get("Records", []):
            bucket = s3_record["s3"]["bucket"]["name"]
            key = urllib.parse.unquote_plus(s3_record["s3"]["object"]["key"])
            size = s3_record["s3"]["object"].get("size", 0)

            print(f"Processing: s3://{bucket}/{key} (size: {size} bytes)")

            # Download the PDF
            response = s3.get_object(Bucket=bucket, Key=key)
            pdf_bytes = response["Body"].read()
            file_size = len(pdf_bytes)

            # Extract text from PDF
            try:
                reader = PdfReader(BytesIO(pdf_bytes))
                pages_text = []
                for i, page in enumerate(reader.pages):
                    text = page.extract_text() or ""
                    pages_text.append(f"--- Page {i + 1} ---\n{text}")
                extracted_text = "\n\n".join(pages_text)
            except Exception as e:
                extracted_text = f"[ERROR extracting text: {str(e)}]"

            # Build output content
            base_name = os.path.splitext(os.path.basename(key))[0]
            output_key = f"processed/{base_name}.txt"

            output_content = (
                f"Source: s3://{bucket}/{key}\n"
                f"File Size: {file_size} bytes ({file_size / 1024:.1f} KB)\n"
                f"Pages: {len(reader.pages)}\n"
                f"{'=' * 60}\n\n"
                f"{extracted_text}"
            )

            # Upload text to output bucket
            s3.put_object(
                Bucket=OUTPUT_BUCKET,
                Key=output_key,
                Body=output_content.encode("utf-8"),
                ContentType="text/plain",
            )
            print(f"Stored text at s3://{OUTPUT_BUCKET}/{output_key}")

            # Send finish notification to result queue
            if result_queue_url:
                sqs.send_message(
                    QueueUrl=result_queue_url,
                    MessageBody=json.dumps({
                        "status": "completed",
                        "source_bucket": bucket,
                        "source_key": key,
                        "output_bucket": OUTPUT_BUCKET,
                        "output_key": output_key,
                        "file_size": file_size,
                        "pages": len(reader.pages),
                        "text_length": len(extracted_text),
                    }),
                )
                print("Finish notification sent to SQS")

    return {"statusCode": 200, "body": "OK"}
