# PDF Text Processor — LocalStack

## A Complete Serverless PDF Processing Pipeline Running Locally

This project simulates a production AWS serverless architecture entirely on your local machine using **LocalStack**. You upload a PDF through a web interface, and an event-driven pipeline extracts the text and makes it available for viewing — all using real AWS service APIs (S3, SQS, Lambda) running locally in Docker.

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Data Flow Step-by-Step](#2-data-flow-step-by-step)
3. [Project File Structure](#3-project-file-structure)
4. [Prerequisites](#4-prerequisites)
5. [Quick Start Tutorial](#5-quick-start-tutorial)
6. [File-by-File Deep Dive](#6-file-by-file-deep-dive)
   - 6.1 [docker-compose.yml](#61-docker-composeyml)
   - 6.2 [nginx.conf](#62-nginxconf)
   - 6.3 [init/setup.sh](#63-initsetupsh)
   - 6.4 [lambda/handler.py](#64-lambdahandlerpy)
   - 6.5 [lambda/requirements.txt](#65-lambdarequirementstxt)
   - 6.6 [html/index.html](#66-htmlindexhtml)
7. [How the Services Connect](#7-how-the-services-connect)
8. [Key Concepts Explained](#8-key-concepts-explained)
9. [Debugging & Troubleshooting](#9-debugging--troubleshooting)
10. [Cleanup](#10-cleanup)
11. [Extending the Project](#11-extending-the-project)

---

## 1. Architecture Overview

```
┌─────────────┐     PUT /s3-upload/      ┌──────────────────┐
│             │ ──────────────────────►   │  S3 Bucket       │
│  Browser    │                          │  pdf-uploads      │
│  (HTML UI)  │                          └────────┬─────────┘
│  port 8080  │                                   │
│             │                          S3 Event Notification
│             │                          (on *.pdf created)
│             │                                   │
│             │                                   ▼
│             │                          ┌──────────────────┐
│             │                          │  SQS Queue        │
│             │                          │  upload-notifs    │
│             │                          └────────┬─────────┘
│             │                                   │
│             │                          Event Source Mapping
│             │                          (triggers Lambda)
│             │                                   │
│             │                                   ▼
│             │                          ┌──────────────────┐
│             │                          │  Lambda Function  │
│             │                          │  pdf-processor    │
│             │                          │  - downloads PDF  │
│             │                          │  - extracts text  │
│             │                          │  - stores .txt    │
│             │                          └──┬──────────┬────┘
│             │                             │          │
│             │                             ▼          ▼
│             │  GET /s3-output/   ┌─────────────┐ ┌──────────────┐
│             │ ◄──────────────── │ S3 Bucket    │ │ SQS Queue    │
│             │  (list & read)    │ pdf-text-out │ │ proc-results │
│             │                   └─────────────┘ └──────────────┘
│             │  GET /sqs/                              │
│             │ ◄───────────────────────────────────────┘
│             │  (poll for completion messages)
└─────────────┘
```

All of this runs through two Docker containers: **LocalStack** (emulating AWS) and **Nginx** (serving the HTML and proxying API calls).

---

## 2. Data Flow Step-by-Step

Here is exactly what happens when you upload a PDF:

1. **User drops a PDF** onto the web page at `http://localhost:8080`.
2. **Browser sends `PUT`** request to `/s3-upload/uploads/filename.pdf` (Nginx proxy).
3. **Nginx rewrites** the URL to `/pdf-uploads/uploads/filename.pdf` and forwards it to LocalStack's S3 API.
4. **LocalStack S3** stores the file in the `pdf-uploads` bucket.
5. **S3 Event Notification** fires because the bucket is configured to send notifications to SQS when any `.pdf` file is created.
6. **SQS `upload-notifications`** queue receives a message containing the S3 event details (bucket name, object key, file size).
7. **Event Source Mapping** (configured between SQS and Lambda) detects the new message and triggers the Lambda function.
8. **Lambda `pdf-processor`** executes:
   - Parses the SQS message to get the S3 bucket/key.
   - Downloads the PDF from S3 using `boto3`.
   - Extracts text from every page using `pypdf`.
   - Builds an output text file with metadata (source path, file size, page count) plus all extracted text.
   - Uploads the `.txt` file to the `pdf-text-output` S3 bucket under `processed/filename.txt`.
   - Sends a JSON completion message to the `processing-results` SQS queue.
9. **Browser polls** the `processing-results` SQS queue every 4 seconds via `/sqs/` proxy.
10. **Browser also polls** for the output file by sending `HEAD` requests to `/s3-output/processed/filename.txt` every 2 seconds.
11. **When the file appears**, the upload status changes to "Done" and the file list refreshes.
12. **User clicks a text file** → browser fetches its contents via `/s3-output/processed/filename.txt` and displays it in the viewer panel.

---

## 3. Project File Structure

```
pdf-processor/
│
├── docker-compose.yml          # Defines the two services: LocalStack + Nginx
├── nginx.conf                  # Nginx config: static files + reverse proxy to LocalStack
├── README.md                   # This documentation file
│
├── html/
│   └── index.html              # Single-page web UI (HTML + CSS + JavaScript)
│
├── lambda/
│   ├── handler.py              # Python Lambda function: PDF → text extraction
│   └── requirements.txt        # Python dependencies for the Lambda (pypdf, boto3)
│
└── init/
    └── setup.sh                # Shell script that creates all AWS resources on startup
```

---

## 4. Prerequisites

- **Docker** (version 20.10+) and **Docker Compose** (v2+)
- **Ports available**: `4566` (LocalStack) and `8080` (Web UI)
- **Disk space**: ~1 GB for the LocalStack image
- **No AWS account needed** — everything runs locally

Verify Docker is installed:

```bash
docker --version        # Should show 20.10+
docker compose version  # Should show v2+
```

---

## 5. Quick Start Tutorial

### Step 1: Unzip and Enter Directory

```bash
unzip pdf-processor.zip -d pdf-processor
cd pdf-processor
```

### Step 2: Start the Services

```bash
docker compose up -d
```

This pulls images (first time only), starts LocalStack, waits for it to be healthy, then starts Nginx.

### Step 3: Watch Initialization

```bash
docker logs localstack -f
```

Wait until you see:

```
============================================
  All resources initialized!
  Upload bucket:  s3://pdf-uploads
  Output bucket:  s3://pdf-text-output
  ...
  Open http://localhost:8080 in your browser
============================================
```

This takes approximately 20-40 seconds.

### Step 4: Open the Web UI

Open **http://localhost:8080** in your browser.

### Step 5: Upload a PDF

Drag and drop any PDF file onto the upload area, or click "browse files" to select one. Watch the Event Log panel on the left — you will see:

1. "Uploading filename.pdf" — file being sent to S3
2. "Uploaded filename.pdf -> S3 notification sent to SQS" — upload complete
3. Status changes from **Uploading** → **Processing** → **Done**

### Step 6: View Extracted Text

The right panel "Processed Files" will show the `.txt` file. Click it to open the text viewer showing the extracted content with metadata.

### Step 7: Stop When Done

```bash
docker compose down -v    # -v removes the named volume too
```

---

## 6. File-by-File Deep Dive

### 6.1 docker-compose.yml

This file defines the two Docker services and how they are wired together.

```yaml
version: "3.8"
```

**Line 1** — Uses Docker Compose file format version 3.8. This specifies which Compose features are available (health checks, dependency conditions, etc.).

---

```yaml
services:
  localstack:
    image: localstack/localstack:3.5
    container_name: localstack
```

**Lines 3-5** — Defines the `localstack` service. Pulls the official LocalStack Docker image version 3.5. The `container_name: localstack` gives it a fixed name so Nginx can reference it by hostname `localstack` in the Docker network.

---

```yaml
    ports:
      - "4566:4566"
```

**Lines 6-7** — Maps LocalStack's gateway port to your host. Port `4566` is LocalStack's unified API endpoint — **all** AWS services (S3, SQS, Lambda, IAM) are accessible through this single port. This is exposed so you can also interact with LocalStack directly from your host via `awslocal` CLI if needed.

---

```yaml
    environment:
      - SERVICES=s3,sqs,lambda,iam
      - DEBUG=1
      - LAMBDA_EXECUTOR=docker
      - DOCKER_HOST=unix:///var/run/docker.sock
      - AWS_DEFAULT_REGION=us-east-1
```

**Lines 8-13** — Environment variables that configure LocalStack:

| Variable | Purpose |
|---|---|
| `SERVICES=s3,sqs,lambda,iam` | Only start these 4 AWS services (faster startup than loading all services) |
| `DEBUG=1` | Enables verbose logging inside LocalStack (useful for troubleshooting) |
| `LAMBDA_EXECUTOR=docker` | Run Lambda functions inside separate Docker containers (production-like isolation) |
| `DOCKER_HOST=unix:///var/run/docker.sock` | Tells LocalStack where the Docker daemon socket is so it can spawn Lambda containers |
| `AWS_DEFAULT_REGION=us-east-1` | Sets the default AWS region for all services |

---

```yaml
    volumes:
      - "./init:/etc/localstack/init/ready.d"
      - "./lambda:/opt/lambda"
      - "/var/run/docker.sock:/var/run/docker.sock"
      - "localstack-data:/var/lib/localstack"
```

**Lines 14-18** — Mount points that connect host files to the container:

| Mount | Purpose |
|---|---|
| `./init -> /etc/localstack/init/ready.d` | LocalStack automatically executes any `.sh` scripts in this directory **after** all services are ready. This is how `setup.sh` runs automatically on startup. |
| `./lambda -> /opt/lambda` | Makes the Lambda source code available inside the container so `setup.sh` can package it into a zip. |
| `docker.sock -> docker.sock` | Gives LocalStack access to the host's Docker daemon so it can create Lambda execution containers. |
| `localstack-data` | Named Docker volume for persistent LocalStack state (survives container restarts). |

---

```yaml
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:4566/_localstack/health"]
      interval: 5s
      timeout: 5s
      retries: 10
```

**Lines 19-23** — Docker health check that pings LocalStack's internal health endpoint every 5 seconds. After 10 failures (50 seconds), the container is marked unhealthy. This is critical because the `web` service depends on this health status.

---

```yaml
  web:
    image: nginx:alpine
    container_name: web-ui
    ports:
      - "8080:80"
```

**Lines 25-29** — The Nginx web server service. Uses the lightweight Alpine-based Nginx image. Maps host port `8080` to container port `80`. This is what you open in your browser.

---

```yaml
    volumes:
      - "./html:/usr/share/nginx/html:ro"
      - "./nginx.conf:/etc/nginx/conf.d/default.conf:ro"
```

**Lines 30-32** — Mounts:

| Mount | Purpose |
|---|---|
| `./html -> /usr/share/nginx/html` | The HTML directory becomes Nginx's document root. `:ro` means read-only. |
| `./nginx.conf -> default.conf` | Replaces the default Nginx site configuration with our custom config that includes the reverse proxy rules. |

---

```yaml
    depends_on:
      localstack:
        condition: service_healthy
```

**Lines 33-35** — Nginx will **not start** until LocalStack passes its health check. This prevents the UI from loading before the AWS resources exist. Without this, API calls from the browser would fail because S3 buckets and SQS queues have not been created yet.

---

```yaml
volumes:
  localstack-data:
```

**Lines 37-38** — Declares the named volume used by LocalStack. Named volumes persist across `docker compose down` (but are removed with `docker compose down -v`).

---

### 6.2 nginx.conf

This file configures Nginx to serve the HTML page and reverse-proxy API calls to LocalStack, eliminating all CORS issues.

```nginx
server {
    listen 80;
    server_name localhost;
    root /usr/share/nginx/html;
    index index.html;
```

**Lines 1-5** — Defines a virtual server listening on port 80. `root` sets the document root directory where static files live. `index` tells Nginx that `index.html` is the default file when a directory is requested.

---

```nginx
    location / {
        try_files $uri $uri/ /index.html;
    }
```

**Lines 7-9** — The catch-all location block for static file serving. `try_files` works left to right: first tries to serve the exact URI as a file (`$uri`), then as a directory (`$uri/`), then falls back to `/index.html`. This is a standard pattern for single-page applications.

---

```nginx
    location /s3-upload/ {
        rewrite ^/s3-upload/(.*) /pdf-uploads/$1 break;
        proxy_pass http://localstack:4566;
        proxy_set_header Host localstack;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        client_max_body_size 100M;
    }
```

**Lines 12-19** — Reverse proxy for S3 uploads. This is the key to avoiding CORS:

| Line | What It Does |
|---|---|
| `rewrite ^/s3-upload/(.*) /pdf-uploads/$1 break;` | Strips `/s3-upload/` prefix and prepends `/pdf-uploads/` (the S3 bucket name). So `/s3-upload/uploads/test.pdf` becomes `/pdf-uploads/uploads/test.pdf`. The `break` flag stops further rewrite processing. |
| `proxy_pass http://localstack:4566;` | Forwards the rewritten request to LocalStack. Uses the Docker internal hostname `localstack` (from `container_name`). |
| `proxy_set_header Host localstack;` | Sets the Host header so LocalStack routes the request correctly. |
| `proxy_http_version 1.1;` | Uses HTTP/1.1 for the upstream connection (required for keep-alive). |
| `proxy_set_header Connection "";` | Enables connection pooling between Nginx and LocalStack. |
| `client_max_body_size 100M;` | Allows PDF uploads up to 100 MB (Nginx defaults to 1 MB which would reject larger files). |

**Why this works (CORS explanation):** The browser loads the page from `http://localhost:8080`. If JavaScript tried to `fetch('http://localhost:4566/...')`, the browser would block it because the origin (`8080`) differs from the target (`4566`) — this is a cross-origin request. By routing through `/s3-upload/` on the same origin (`8080`), Nginx handles the cross-origin hop server-side where CORS does not apply.

---

```nginx
    location /s3-output/ {
        rewrite ^/s3-output/(.*) /pdf-text-output/$1 break;
        proxy_pass http://localstack:4566;
        proxy_set_header Host localstack;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
    }
```

**Lines 22-28** — Identical pattern for the output bucket. `/s3-output/processed/file.txt` becomes `/pdf-text-output/processed/file.txt` on LocalStack. No `client_max_body_size` needed here because we only read from this bucket.

---

```nginx
    location /sqs/ {
        rewrite ^/sqs/(.*) /000000000000/$1 break;
        proxy_pass http://localstack:4566;
        proxy_set_header Host localstack;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
    }
```

**Lines 31-37** — Proxy for SQS API calls. LocalStack SQS URLs follow the pattern `/{account_id}/{queue_name}`. The account `000000000000` is LocalStack's default dummy account. So `/sqs/processing-results?Action=ReceiveMessage` becomes `/000000000000/processing-results?Action=ReceiveMessage`.

---

### 6.3 init/setup.sh

This is the initialization script that creates all AWS resources. LocalStack auto-executes any script placed in `/etc/localstack/init/ready.d/` after all services are ready.

```bash
#!/bin/bash
set -euo pipefail
```

**Lines 1-2** — Shebang line (`#!/bin/bash`) tells the OS to use bash. `set -euo pipefail` enables strict mode: `-e` exits on any error, `-u` treats unset variables as errors, `-o pipefail` makes piped commands fail if any part fails. This prevents silent failures during setup.

---

```bash
REGION="us-east-1"
ENDPOINT="http://localhost:4566"
AWS="aws --endpoint-url=$ENDPOINT --region=$REGION"
```

**Lines 7-9** — Configuration variables. The `AWS` variable creates a shorthand for running AWS CLI commands against LocalStack. Every AWS CLI call needs `--endpoint-url` to point at LocalStack instead of real AWS.

---

```bash
UPLOAD_BUCKET="pdf-uploads"
OUTPUT_BUCKET="pdf-text-output"
UPLOAD_QUEUE="upload-notifications"
RESULT_QUEUE="processing-results"
LAMBDA_NAME="pdf-processor"
```

**Lines 11-15** — Names for all AWS resources. These are referenced throughout the script and must match what the HTML and Lambda code expect.

---

#### Step 1: Create S3 Buckets

```bash
$AWS s3 mb s3://$UPLOAD_BUCKET 2>/dev/null || true
$AWS s3 mb s3://$OUTPUT_BUCKET 2>/dev/null || true
```

**Lines 18-19** — `s3 mb` means "make bucket". Creates two S3 buckets. `2>/dev/null || true` suppresses errors and prevents the script from exiting if the buckets already exist (idempotent). This is important because the init script might run again if the container restarts.

- **`pdf-uploads`** — Receives uploaded PDFs from the web UI.
- **`pdf-text-output`** — Stores the extracted `.txt` files after Lambda processing.

---

#### Step 2: Create SQS Queues

```bash
UPLOAD_QUEUE_URL=$($AWS sqs create-queue --queue-name $UPLOAD_QUEUE --query 'QueueUrl' --output text)
RESULT_QUEUE_URL=$($AWS sqs create-queue --queue-name $RESULT_QUEUE --query 'QueueUrl' --output text)
```

**Lines 23-25** — Creates two SQS queues and captures their URLs. `--query 'QueueUrl' --output text` uses JMESPath to extract just the URL string from the JSON response.

- **`upload-notifications`** — Receives S3 event notifications when a PDF is uploaded.
- **`processing-results`** — Receives completion messages from the Lambda after processing.

---

```bash
UPLOAD_QUEUE_ARN=$($AWS sqs get-queue-attributes \
    --queue-url "$UPLOAD_QUEUE_URL" \
    --attribute-names QueueArn \
    --query 'Attributes.QueueArn' --output text)
```

**Lines 29-32** — Retrieves the ARN (Amazon Resource Name) of the upload queue. ARNs are unique identifiers in AWS — we need this ARN to configure the S3 notification (S3 needs to know which queue to send to by ARN, not URL).

---

```bash
$AWS sqs set-queue-attributes \
    --queue-url "$UPLOAD_QUEUE_URL" \
    --attributes '{
        "Policy": "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Principal\":\"*\",\"Action\":\"sqs:SendMessage\",\"Resource\":\"*\"}]}"
    }'
```

**Lines 36-40** — Sets a resource-based IAM policy on the SQS queue that allows **any** service (Principal: `*`) to send messages to it. In real AWS, you would restrict this to only the S3 bucket's ARN. For LocalStack, a permissive policy is sufficient. Without this policy, S3 would get "Access Denied" when trying to notify SQS.

---

#### Step 3: Configure S3 -> SQS Event Notification

```bash
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
```

**Lines 43-59** — This is the critical link that connects S3 to SQS. It tells the `pdf-uploads` bucket: "Whenever a new object is created (`s3:ObjectCreated:*`) and its key ends in `.pdf`, send a notification message to this SQS queue."

| Field | Purpose |
|---|---|
| `QueueArn` | Identifies which SQS queue receives the notification |
| `Events: ["s3:ObjectCreated:*"]` | Triggers on any object creation (PUT, POST, COPY, multipart upload) |
| `FilterRules: suffix .pdf` | Only triggers for files ending in `.pdf` (ignores other file types) |

The notification message that S3 sends to SQS contains a JSON body with the bucket name, object key, file size, and other metadata. The Lambda parses this message structure.

---

#### Step 4: Build Lambda Deployment Package

```bash
LAMBDA_DIR="/opt/lambda"
BUILD_DIR="/tmp/lambda-build"
rm -rf $BUILD_DIR
mkdir -p $BUILD_DIR

pip install -q -t $BUILD_DIR pypdf==4.1.0 2>/dev/null
cp $LAMBDA_DIR/handler.py $BUILD_DIR/

cd $BUILD_DIR
zip -q -r /tmp/lambda.zip .
```

**Lines 63-72** — Lambda functions in AWS are deployed as ZIP archives containing all code and dependencies. This section:

1. Creates a clean build directory (`/tmp/lambda-build`).
2. Installs `pypdf` (the PDF parsing library) into the build directory using `pip install -t` (which installs into a target directory instead of system-wide).
3. Copies `handler.py` into the build directory.
4. Zips everything into `/tmp/lambda.zip`.

The resulting ZIP contains `handler.py` plus all `pypdf` dependency files at the top level, which is how Lambda expects the package structure.

---

#### Step 5: Create Lambda Function

```bash
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
```

**Lines 80-98** — Creates (or updates) the Lambda function:

| Parameter | Purpose |
|---|---|
| `--function-name pdf-processor` | Name of the Lambda function |
| `--runtime python3.11` | Lambda execution runtime |
| `--handler handler.handler` | Entry point: file `handler.py`, function `handler()` |
| `--zip-file fileb:///tmp/lambda.zip` | The deployment package. `fileb://` means "file in binary mode" |
| `--role arn:aws:iam::000000000000:role/lambda-role` | IAM role for the Lambda (LocalStack does not enforce permissions, so this is a placeholder) |
| `--timeout 120` | Maximum execution time: 2 minutes (PDF processing can be slow) |
| `--memory-size 512` | Allocates 512 MB RAM to the Lambda (needed for parsing large PDFs) |

**Environment variables passed to the Lambda:**

| Variable | Value | Purpose |
|---|---|---|
| `AWS_ENDPOINT_URL` | `http://localhost.localstack.cloud:4566` | How the Lambda calls back to LocalStack. This special hostname resolves to the correct address from within Lambda execution containers. |
| `OUTPUT_BUCKET` | `pdf-text-output` | Where to store extracted text files |
| `RESULT_QUEUE_URL` | `http://localhost:4566/...` | SQS queue URL for completion notifications |
| `AWS_DEFAULT_REGION` | `us-east-1` | AWS region |

The `|| update-function-code` fallback handles re-runs: if the function already exists, it just updates the code.

---

#### Step 6: Create SQS -> Lambda Event Source Mapping

```bash
$AWS lambda create-event-source-mapping \
    --function-name $LAMBDA_NAME \
    --event-source-arn "$UPLOAD_QUEUE_ARN" \
    --batch-size 1 \
    --enabled
```

**Lines 101-106** — This is the final link in the chain. An event source mapping tells Lambda: "Poll this SQS queue, and whenever a message arrives, invoke this function with the message as the event payload."

| Parameter | Purpose |
|---|---|
| `--event-source-arn` | The ARN of the `upload-notifications` queue |
| `--batch-size 1` | Process one message at a time (each PDF gets its own Lambda invocation) |
| `--enabled` | Start polling immediately |

Without this mapping, messages would pile up in SQS but nothing would process them.

---

### 6.4 lambda/handler.py

This is the Python Lambda function that does the actual PDF-to-text conversion.

#### Imports and Configuration

```python
import json
import os
import boto3
import urllib.parse
from io import BytesIO

from pypdf import PdfReader
```

**Lines 1-8** — Module imports:

| Import | Purpose |
|---|---|
| `json` | Parse SQS message bodies and create JSON for the completion message |
| `os` | Read environment variables, manipulate file paths |
| `boto3` | AWS SDK for Python — used to interact with S3 and SQS |
| `urllib.parse` | Decode URL-encoded S3 object keys (e.g. spaces encoded as `%20`) |
| `BytesIO` | Wraps raw bytes in a file-like object so `pypdf` can read the PDF from memory |
| `PdfReader` | The `pypdf` class that parses PDF files and extracts text |

---

```python
ENDPOINT_URL = os.environ.get("AWS_ENDPOINT_URL", "http://localhost.localstack.cloud:4566")
REGION = os.environ.get("AWS_DEFAULT_REGION", "us-east-1")
OUTPUT_BUCKET = os.environ.get("OUTPUT_BUCKET", "pdf-text-output")
RESULT_QUEUE_NAME = os.environ.get("RESULT_QUEUE_URL", "")
```

**Lines 10-13** — Configuration from environment variables (set during `lambda create-function` in setup.sh). Each has a sensible default as a fallback.

The `ENDPOINT_URL` is `http://localhost.localstack.cloud:4566` — this is a special DNS name that LocalStack provides. When Lambda runs in a separate Docker container, it needs to reach back to the LocalStack container. `localhost.localstack.cloud` resolves to the correct address in LocalStack's Docker networking.

---

#### Client Factory

```python
def get_clients():
    kwargs = {
        "region_name": REGION,
        "endpoint_url": ENDPOINT_URL,
        "aws_access_key_id": "test",
        "aws_secret_access_key": "test",
    }
    s3 = boto3.client("s3", **kwargs)
    sqs = boto3.client("sqs", **kwargs)
    result_queue_url = f"{ENDPOINT_URL}/000000000000/processing-results"
    return s3, sqs, result_queue_url
```

**Lines 16-27** — Creates boto3 clients for S3 and SQS, pointed at LocalStack instead of real AWS. The credentials `test/test` are LocalStack's default — it does not validate credentials. The result queue URL is constructed using the Lambda's endpoint so SQS calls route correctly.

---

#### Main Handler Function

```python
def handler(event, context):
    s3, sqs, result_queue_url = get_clients()
```

**Lines 30-31** — The Lambda entry point. AWS Lambda calls `handler(event, context)` when triggered. `event` contains the SQS message(s), `context` has Lambda runtime info (timeout, request ID, etc.).

---

```python
    for record in event.get("Records", []):
        body = json.loads(record.get("body", "{}"))

        for s3_record in body.get("Records", []):
```

**Lines 33-37** — Navigates the nested event structure. When SQS triggers Lambda:

- `event["Records"]` — List of SQS messages (we set batch size to 1, so usually just one).
- Each SQS record has a `body` field containing the stringified JSON of the S3 notification.
- `body["Records"]` — The S3 event can contain multiple object notifications.

The structure is: `Lambda Event -> SQS Records -> S3 Notification Body -> S3 Records`.

---

```python
            bucket = s3_record["s3"]["bucket"]["name"]
            key = urllib.parse.unquote_plus(s3_record["s3"]["object"]["key"])
            size = s3_record["s3"]["object"].get("size", 0)
```

**Lines 38-40** — Extracts the S3 object details from the notification:
- `bucket` — Which S3 bucket (`pdf-uploads`)
- `key` — The object key (path), URL-decoded. `unquote_plus` handles encoded characters like `%20` -> space, `%2B` -> `+`.
- `size` — File size in bytes as reported by S3.

---

```python
            response = s3.get_object(Bucket=bucket, Key=key)
            pdf_bytes = response["Body"].read()
            file_size = len(pdf_bytes)
```

**Lines 45-47** — Downloads the PDF from S3. `get_object` returns a streaming response; `.read()` pulls all bytes into memory. `file_size` is the actual byte count (more reliable than the S3 notification size).

---

```python
            try:
                reader = PdfReader(BytesIO(pdf_bytes))
                pages_text = []
                for i, page in enumerate(reader.pages):
                    text = page.extract_text() or ""
                    pages_text.append(f"--- Page {i + 1} ---\n{text}")
                extracted_text = "\n\n".join(pages_text)
            except Exception as e:
                extracted_text = f"[ERROR extracting text: {str(e)}]"
```

**Lines 50-58** — The PDF text extraction core:

1. `PdfReader(BytesIO(pdf_bytes))` — Wraps the raw bytes in a file-like object and creates a PDF reader. `pypdf` can parse the PDF structure from this.
2. Iterates through `reader.pages` — each `page` object represents one PDF page.
3. `page.extract_text()` — Extracts all text content from the page. Returns `None` for pages with no extractable text (e.g. scanned images), so `or ""` handles that.
4. Each page's text is prefixed with a header like `--- Page 1 ---` for readability.
5. All pages are joined with double newlines.
6. The `try/except` ensures corrupted or encrypted PDFs do not crash the Lambda — instead, an error message is stored.

---

```python
            base_name = os.path.splitext(os.path.basename(key))[0]
            output_key = f"processed/{base_name}.txt"
```

**Lines 61-62** — Generates the output file path. `os.path.basename` extracts `report.pdf` from `uploads/report.pdf`. `os.path.splitext` splits it into `('report', '.pdf')` and `[0]` takes `report`. The output key becomes `processed/report.txt`.

---

```python
            output_content = (
                f"Source: s3://{bucket}/{key}\n"
                f"File Size: {file_size} bytes ({file_size / 1024:.1f} KB)\n"
                f"Pages: {len(reader.pages)}\n"
                f"{'=' * 60}\n\n"
                f"{extracted_text}"
            )
```

**Lines 64-70** — Builds the output text file content. The header contains metadata (source path, file size, page count) followed by a separator line and all extracted text. The `:.1f` format gives one decimal place for the KB value.

---

```python
            s3.put_object(
                Bucket=OUTPUT_BUCKET,
                Key=output_key,
                Body=output_content.encode("utf-8"),
                ContentType="text/plain",
            )
```

**Lines 73-78** — Uploads the text file to the output S3 bucket. `.encode("utf-8")` converts the string to bytes (S3 stores binary data). `ContentType` is set so browsers/tools handle the file correctly.

---

```python
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
```

**Lines 82-95** — Sends a completion notification to the `processing-results` SQS queue. This JSON message tells the browser (which polls this queue) that processing is finished and includes details about the result. The browser uses this to update the UI in real-time.

---

```python
    return {"statusCode": 200, "body": "OK"}
```

**Line 98** — Lambda return value. For SQS-triggered Lambdas, the return value is not sent back to SQS, but it is good practice to return a success response for logging.

---

### 6.5 lambda/requirements.txt

```
pypdf==4.1.0
boto3==1.34.0
```

**Line 1** — `pypdf` version 4.1.0 is the PDF parsing library. It is a pure Python library (no C dependencies) which makes it easy to package for Lambda.

**Line 2** — `boto3` is the AWS SDK. Lambda runtimes include boto3 by default in real AWS, but for LocalStack we include it explicitly to ensure it is available.

---

### 6.6 html/index.html

This is a single-file web application — all HTML, CSS, and JavaScript in one file.

#### API Configuration (JavaScript)

```javascript
const API = {
  upload: (key) => `/s3-upload/${key}`,
  outputList: () => `/s3-output/?list-type=2&prefix=processed/`,
  outputFile: (key) => `/s3-output/${key}`,
  outputHead: (key) => `/s3-output/${key}`,
  sqsReceive: () => `/sqs/processing-results?Action=ReceiveMessage&MaxNumberOfMessages=10&WaitTimeSeconds=0&VisibilityTimeout=30`,
  sqsDelete: (receipt) => `/sqs/processing-results?Action=DeleteMessage&ReceiptHandle=${encodeURIComponent(receipt)}`,
};
```

All API paths start with `/s3-upload/`, `/s3-output/`, or `/sqs/` — these match the Nginx proxy `location` blocks. The browser never talks directly to LocalStack port 4566.

| Method | URL Pattern | What It Does |
|---|---|---|
| `upload(key)` | `PUT /s3-upload/uploads/file.pdf` | Uploads a PDF to S3 |
| `outputList()` | `GET /s3-output/?list-type=2&prefix=processed/` | Lists all files in the `processed/` prefix of the output bucket (S3 ListObjectsV2 API) |
| `outputFile(key)` | `GET /s3-output/processed/file.txt` | Downloads a text file's contents |
| `outputHead(key)` | `HEAD /s3-output/processed/file.txt` | Checks if a file exists without downloading it (used for polling) |
| `sqsReceive()` | `GET /sqs/processing-results?Action=ReceiveMessage...` | Polls SQS for completion messages. `VisibilityTimeout=30` hides received messages for 30s so they are not processed twice. |
| `sqsDelete(receipt)` | `GET /sqs/processing-results?Action=DeleteMessage...` | Deletes a processed message from SQS using its `ReceiptHandle` token. |

---

#### Initialization

```javascript
document.addEventListener('DOMContentLoaded', () => {
  setupDropZone();
  refreshFileList();
  startPolling();
  refreshInterval = setInterval(refreshFileList, 5000);
});
```

When the page loads: sets up drag-and-drop handlers, loads the current file list, starts SQS polling, and sets a 5-second auto-refresh interval for the file list.

---

#### Upload Function

```javascript
async function uploadFile(file) {
  const id = Date.now() + '-' + Math.random().toString(36).slice(2, 7);
  const key = `uploads/${file.name}`;
  // ... UI updates ...
  const response = await fetch(API.upload(key), {
    method: 'PUT',
    body: file,
    headers: { 'Content-Type': 'application/pdf' },
  });
```

Uploads the file directly to S3 using an HTTP `PUT` with the raw file as the body. S3's REST API accepts `PUT /{bucket}/{key}` to create an object. The file is sent as-is — no multipart form encoding needed.

---

#### Completion Polling

```javascript
async function pollForCompletion(uploadId, fileName) {
  const baseName = fileName.replace(/\.pdf$/i, '');
  let attempts = 0;
  const maxAttempts = 60;

  const check = async () => {
    attempts++;
    const res = await fetch(API.outputHead(`processed/${baseName}.txt`), { method: 'HEAD' });
    if (res.ok) { /* file exists -> mark done */ }
    else if (attempts < maxAttempts) setTimeout(check, 2000);
  };

  setTimeout(check, 3000);
}
```

After uploading, starts checking every 2 seconds whether the output `.txt` file exists (using HTTP `HEAD` — no body downloaded). Waits 3 seconds initially to give Lambda time to start. Times out after 120 seconds (60 attempts x 2 seconds).

---

#### File List (S3 ListObjectsV2)

```javascript
async function refreshFileList() {
  const res = await fetch(API.outputList());
  const text = await res.text();
  const parser = new DOMParser();
  const xml = parser.parseFromString(text, 'text/xml');
  const contents = xml.querySelectorAll('Contents');
  // ... iterate and render each file entry ...
}
```

Calls the S3 `ListObjectsV2` API (via `?list-type=2&prefix=processed/`). S3 returns an XML response listing all objects. The browser parses this XML using `DOMParser` and extracts each `<Contents>` element (which has `<Key>`, `<Size>`, `<LastModified>`).

---

#### SQS Polling

```javascript
async function pollResultQueue() {
  const res = await fetch(API.sqsReceive());
  const text = await res.text();
  const xml = parser.parseFromString(text, 'text/xml');
  const messages = xml.querySelectorAll('Message');

  messages.forEach(msg => {
    const body = JSON.parse(msg.querySelector('Body').textContent);
    const receipt = msg.querySelector('ReceiptHandle').textContent;
    // ... log the completion event ...
    fetch(API.sqsDelete(receipt)); // Delete the processed message
  });
}
```

Polls SQS every 4 seconds for completion messages. SQS also returns XML. Each message is parsed, logged to the event panel, and then deleted from the queue (so it is not processed again). The `ReceiptHandle` is required for deletion — it is a temporary token that identifies the specific receipt of a specific message.

---

#### CSS Design System

The CSS uses CSS custom properties (variables) for a consistent dark theme:

| Variable | Value | Use |
|---|---|---|
| `--bg` | `#0c0c0f` | Page background |
| `--surface` | `#16161c` | Card backgrounds |
| `--surface-raised` | `#1e1e26` | Elevated elements (inputs, code blocks) |
| `--border` | `#2a2a35` | Border color |
| `--text` | `#e8e6f0` | Primary text |
| `--text-dim` | `#8a8898` | Secondary/muted text |
| `--accent` | `#6c5ce7` | Interactive elements (purple) |
| `--success` | `#00d2a0` | Success states (green) |
| `--warn` | `#f0a030` | Processing states (amber) |
| `--danger` | `#ff5b5b` | Error states (red) |

---

## 7. How the Services Connect

Here is a summary of every connection between components:

```
 ┌───────────────── Docker Compose Network ─────────────────┐
 │                                                          │
 │  ┌─────────────┐         ┌────────────────────────────┐  │
 │  │   nginx     │  proxy  │      localstack             │  │
 │  │   (web)     │ ──────> │                             │  │
 │  │             │         │  ┌──────┐    ┌──────┐       │  │
 │  │  port 80 <──┼── 8080 │  │  S3  │    │  SQS │       │  │
 │  │             │         │  └──┬───┘    └──┬───┘       │  │
 │  │  /s3-upload ────────────>  │           │            │  │
 │  │  /s3-output <──────────── │           │            │  │
 │  │  /sqs ─────────────────────────────>  │            │  │
 │  │             │         │     │    event  │            │  │
 │  └─────────────┘         │     │ ──notif──>│            │  │
 │                          │     │           │            │  │
 │                          │  ┌──┴───────────┴──┐        │  │
 │                          │  │    Lambda        │        │  │
 │                          │  │  (spawns in its  │        │  │
 │                          │  │   own container) │        │  │
 │                          │  └─────────────────┘        │  │
 │                          │                    port 4566│  │
 │                          └────────────────────────────┘  │
 └──────────────────────────────────────────────────────────┘
```

Docker Compose creates a shared network. Both services can reach each other by container name (`localstack`, `web-ui`). The browser only talks to Nginx on port 8080. Nginx talks to LocalStack on the internal network. Lambda containers use `localhost.localstack.cloud:4566` to reach back to LocalStack.

---

## 8. Key Concepts Explained

### What is LocalStack?

LocalStack is a cloud emulator that runs AWS services on your local machine. Instead of provisioning real AWS resources (and paying for them), you run identical API calls against `localhost:4566`. LocalStack supports S3, SQS, Lambda, DynamoDB, and many more services.

### What is an S3 Event Notification?

S3 buckets can be configured to send notifications when objects are created, deleted, or modified. Notifications can go to SQS, SNS, or Lambda directly. In this project, we use S3 -> SQS because it decouples the upload from processing and provides built-in retry via SQS.

### What is an SQS Event Source Mapping?

An event source mapping is an AWS Lambda resource that polls an SQS queue and invokes the Lambda function when messages are available. Lambda manages the polling, batching, and retry logic. If the Lambda fails, the message becomes visible in SQS again after the visibility timeout.

### Why Nginx as a Reverse Proxy?

Browsers enforce the Same-Origin Policy: JavaScript on `localhost:8080` cannot make requests to `localhost:4566` without CORS headers. Rather than configuring complex CORS rules, we route all API traffic through Nginx on the same origin. This is also how production apps work — frontend and API are served from the same domain.

### Why `localhost.localstack.cloud`?

When LocalStack runs Lambda functions, it spawns them in separate Docker containers. These containers need to call back to LocalStack (to access S3, SQS, etc.). `localhost.localstack.cloud` is a special hostname provided by LocalStack that resolves correctly from within these spawned containers.

---

## 9. Debugging & Troubleshooting

### Check if LocalStack is Running

```bash
curl http://localhost:4566/_localstack/health
```

You should see JSON showing the status of each service (e.g. `"s3": "running"`).

### Check if Resources Were Created

```bash
# List S3 buckets
docker exec localstack awslocal s3 ls

# List SQS queues
docker exec localstack awslocal sqs list-queues

# List Lambda functions
docker exec localstack awslocal lambda list-functions

# List event source mappings
docker exec localstack awslocal lambda list-event-source-mappings
```

### Check Lambda Logs

```bash
docker exec localstack awslocal logs tail /aws/lambda/pdf-processor --follow
```

### Test Upload from CLI

```bash
docker exec localstack awslocal s3 cp /path/to/test.pdf s3://pdf-uploads/uploads/test.pdf
```

### Check SQS Messages

```bash
# Check upload notification queue (should be empty if Lambda is consuming)
docker exec localstack awslocal sqs receive-message \
  --queue-url http://localhost:4566/000000000000/upload-notifications

# Check result queue
docker exec localstack awslocal sqs receive-message \
  --queue-url http://localhost:4566/000000000000/processing-results
```

### Check Output Files

```bash
docker exec localstack awslocal s3 ls s3://pdf-text-output/processed/
docker exec localstack awslocal s3 cp s3://pdf-text-output/processed/test.txt -
```

### Re-run Initialization

If something is missing, you can re-run the setup script:

```bash
docker exec localstack bash /etc/localstack/init/ready.d/setup.sh
```

### Common Issues

| Problem | Cause | Fix |
|---|---|---|
| Page loads but upload fails | LocalStack not ready yet | Wait for health check; check `docker logs localstack` |
| Upload succeeds but never finishes | Lambda not triggering | Check event source mapping exists; check Lambda logs |
| "Processing" stays forever | Lambda error | Check Lambda logs for Python exceptions |
| File list empty after processing | Wrong output bucket/key | Verify `awslocal s3 ls s3://pdf-text-output/processed/` |
| CORS errors in console | Bypassing Nginx proxy | Ensure HTML uses `/s3-upload/` paths, not `localhost:4566` |
| Nginx returns 502 Bad Gateway | LocalStack not reachable | Check `docker ps` — ensure localstack container is running |
| Lambda timeout | PDF too large or complex | Increase `--timeout` in setup.sh |
| Blank text extracted | PDF is scanned images | `pypdf` cannot OCR; need `pytesseract` for scanned PDFs |

---

## 10. Cleanup

Stop and remove everything:

```bash
# Stop containers and remove volumes
docker compose down -v

# Also remove downloaded images (optional, saves disk space)
docker rmi localstack/localstack:3.5 nginx:alpine
```

---

## 11. Extending the Project

Here are ideas for building on this project:

- **Add OCR** — Install `pytesseract` and `pdf2image` in the Lambda to handle scanned PDFs that have no extractable text.
- **Add DynamoDB** — Store processing metadata (filename, size, page count, timestamp) in a DynamoDB table for querying.
- **Add SNS** — Send email or webhook notifications when processing completes.
- **Add Step Functions** — Orchestrate multi-step processing (e.g. extract -> translate -> summarize).
- **Add authentication** — Put Cognito or a simple auth layer in front of the upload.
- **Switch to real AWS** — Remove `--endpoint-url` from the CLI and `endpoint_url` from boto3, set real credentials, and deploy the same architecture to production.

The beauty of LocalStack is that the code is nearly identical to what runs on real AWS. The only difference is the endpoint URL.
