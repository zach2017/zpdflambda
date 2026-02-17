# PDF Text Processor — LocalStack

A complete serverless PDF processing pipeline running entirely on LocalStack.

## Architecture

```
📄 PDF Upload → 🪣 S3 (pdf-uploads) → 📨 SQS (upload-notifications)
                                              ↓
                                        ⚡ Lambda (pdf-processor)
                                              ↓
                                    📝 S3 (pdf-text-output) + ✅ SQS (processing-results)
                                              ↓
                                        🖥️ HTML UI lists & displays text files
```

### Components

| Service | Resource | Purpose |
|---------|----------|---------|
| **S3** | `pdf-uploads` | Receives uploaded PDF files |
| **S3** | `pdf-text-output` | Stores extracted text files |
| **SQS** | `upload-notifications` | Triggered by S3 on new PDF upload |
| **SQS** | `processing-results` | Lambda sends "finished" messages here |
| **Lambda** | `pdf-processor` | Downloads PDF, extracts text, stores result |
| **Nginx** | web UI | Serves HTML page on port 8080 |

## Prerequisites

- Docker & Docker Compose
- Ports `4566` (LocalStack) and `8080` (Web UI) available

## Quick Start

```bash
# Start everything
docker compose up -d

# Wait ~30 seconds for LocalStack to initialize all resources
# Watch the init logs:
docker logs localstack -f

# Open the UI
open http://localhost:8080
```

## Usage

1. **Open** `http://localhost:8080` in your browser
2. **Upload** a PDF file using drag & drop or the file picker
3. **Watch** the event log as the pipeline processes your file:
   - File uploads to S3
   - S3 triggers SQS notification
   - SQS triggers Lambda function
   - Lambda extracts text and stores it in S3
   - Lambda sends completion message to result SQS queue
4. **Click** on any processed text file in the right panel to view its contents
5. The file list **auto-refreshes** every 5 seconds, or click Refresh manually

## File Structure

```
├── docker-compose.yml      # LocalStack + Nginx services
├── nginx.conf              # Nginx reverse proxy config
├── html/
│   └── index.html          # Web UI (upload, list, view)
├── lambda/
│   ├── handler.py          # Lambda function code
│   └── requirements.txt    # Python dependencies
├── init/
│   └── setup.sh            # LocalStack initialization script
└── README.md
```

## Troubleshooting

**Lambda not processing files?**
```bash
# Check Lambda logs
docker exec localstack awslocal logs tail /aws/lambda/pdf-processor --follow
```

**Check if resources are created:**
```bash
docker exec localstack awslocal s3 ls
docker exec localstack awslocal sqs list-queues
docker exec localstack awslocal lambda list-functions
```

**Re-run init script:**
```bash
docker exec localstack bash /etc/localstack/init/ready.d/setup.sh
```

**Manual test — upload a file via CLI:**
```bash
docker exec localstack awslocal s3 cp /some/file.pdf s3://pdf-uploads/uploads/test.pdf
```

## Cleanup

```bash
docker compose down -v
```
