# 📝 NanoGrid v2 - 파트별 상세 개발 요구사항 (R&R)

> **아키텍처 변경**: Lambda 기반 → EC2 Controller 기반 3-Tier 구조  
> **신규 기능**: AI Node (Ollama LLM), Output Binding (S3 결과물 자동 업로드)  
> **최종 수정일**: 2024-12-04

---

## 🏗️ 1. Infrastructure Team (Terraform)

### 📌 목표
Lambda를 철거하고, ALB → Controller → Worker/Redis 3-Tier 구조와 AI 인프라를 구축합니다.

### ✅ 완료된 작업 (Terraform Apply 완료)

#### 1.1 네트워크 구성
```
VPC: nanogrid-vpc (10.0.0.0/16)
├── Public Subnet 1 (10.0.1.0/24, AZ-a) ← Controller EC2, NAT GW
├── Public Subnet 2 (10.0.2.0/24, AZ-c) ← ALB Multi-AZ 요구사항
├── Private-App Subnet (10.0.10.0/24)  ← 현재 미사용 (향후 확장용)
└── Private-Data Subnet (10.0.20.0/24) ← Worker ASG, AI Node, Redis
```

#### 1.2 컴퓨팅 리소스
| 리소스 | 타입 | 위치 | IP | 상태 |
|--------|------|------|-----|------|
| ALB | Application LB | Public Subnet 1,2 | DNS 제공 | ✅ |
| Controller EC2 | t3.small | Public Subnet 1 | 10.0.1.84 | ✅ |
| Worker ASG | t3.small | Private-Data | 동적 할당 | ✅ |
| AI Node EC2 | t3.large | Private-Data | 10.0.20.100 | ✅ |
| Redis | cache.t3.micro | Private-Data | 동적 할당 | ✅ |

#### 1.3 보안 그룹 매트릭스
| SG | Inbound | Source | 용도 |
|----|---------|--------|------|
| alb-sg | 80, 443 | 0.0.0.0/0 | 외부 트래픽 |
| controller-sg | 80 | alb-sg | ALB → Controller |
| controller-sg | 22, 8080 | 0.0.0.0/0 | SSH, Express 직접 접근 |
| worker-sg | - | - | Outbound만 허용 |
| ai-sg | 11434 | worker-sg | Worker → AI Node |
| redis-sg | 6379 | controller-sg, worker-sg | Redis 접근 |

#### 1.4 IAM 권한
**Controller Role:**
- S3: PutObject, GetObject, DeleteObject (`nanogrid-code-bucket`)
- DynamoDB: PutItem, GetItem, UpdateItem, Query, DeleteItem
- SQS: SendMessage, GetQueueAttributes

**Worker Role:**
- S3: GetObject (`nanogrid-code-bucket`), PutObject (`nanogrid-user-data`)
- SQS: ReceiveMessage, DeleteMessage, GetQueueAttributes
- DynamoDB: GetItem
- CloudWatch: Agent 권한

### 🔲 남은 작업
- [ ] HTTPS 인증서 (ACM) 및 ALB HTTPS Listener 추가
- [ ] Route53 도메인 연결 (선택)
- [ ] CloudWatch 대시보드 구성

---

## ⚙️ 2. Backend Team (Controller Node - Express.js)

### 📌 목표
기존 Lambda 2개(Upload, Run)의 역할을 Express.js 서버 하나로 통합합니다.

### 🔲 개발 작업

#### 2.1 EC2 접속 및 환경 설정
```bash
# SSH 접속 (Public IP 또는 Session Manager)
ssh -i key.pem ubuntu@<controller-public-ip>

# 또는 AWS Systems Manager Session Manager 사용
aws ssm start-session --target <instance-id>
```

**환경변수 (Terraform에서 자동 주입됨 - /etc/environment):**
```bash
S3_BUCKET=nanogrid-code-bucket
DYNAMODB_TABLE=NanoGridFunctions
SQS_QUEUE_URL=https://sqs.ap-northeast-2.amazonaws.com/xxx/nanogrid-task-queue
REDIS_HOST=nanogrid-redis.xxx.cache.amazonaws.com
REDIS_PORT=6379
```

#### 2.2 Express 서버 구축 (server.js)

```javascript
// 필요 패키지
// npm install express aws-sdk ioredis uuid multer

const express = require('express');
const AWS = require('aws-sdk');
const Redis = require('ioredis');
const { v4: uuidv4 } = require('uuid');
const multer = require('multer');

const app = express();
const upload = multer({ storage: multer.memoryStorage() });

// AWS 클라이언트
const s3 = new AWS.S3();
const dynamodb = new AWS.DynamoDB.DocumentClient();
const sqs = new AWS.SQS();

// Redis 클라이언트
const redis = new Redis({
  host: process.env.REDIS_HOST,
  port: process.env.REDIS_PORT
});

// Health Check (ALB용 - 필수!)
app.get('/health', (req, res) => {
  res.status(200).json({ status: 'healthy' });
});

// POST /upload - 파일 업로드
app.post('/upload', upload.single('file'), async (req, res) => {
  // 구현 필요
});

// POST /run - 함수 실행
app.post('/run', async (req, res) => {
  // 구현 필요
});

app.listen(80, () => console.log('Controller running on port 80'));
```

#### 2.3 API 상세 스펙

##### `POST /upload` - 함수 등록
```
Request:
  - Content-Type: multipart/form-data
  - Body:
    - file: 소스코드 파일 (.py, .zip 등)
    - function_name: 함수 이름 (string)
    - runtime: 런타임 (python3.9, nodejs18.x 등)
    - handler: 핸들러 (예: main.handler)
    - timeout: 타임아웃 초 (기본 300)

Response (201 Created):
{
  "function_id": "uuid-xxxx",
  "function_name": "my-function",
  "s3_key": "functions/uuid-xxxx/code.zip",
  "created_at": "2024-12-04T10:00:00Z"
}

로직:
1. UUID 생성
2. S3에 파일 업로드 (Key: functions/{function_id}/code.zip)
3. DynamoDB에 메타데이터 저장
   - functionId (PK)
   - functionName
   - s3Key
   - runtime
   - handler
   - timeout
   - createdAt
```

##### `POST /run` - 함수 실행 (동기)
```
Request:
  - Content-Type: application/json
  - Headers:
    - X-Async: true (선택, 비동기 모드)
  - Body:
{
  "function_id": "uuid-xxxx",
  "payload": { "key": "value" }
}

Response (200 OK) - 동기 모드:
{
  "job_id": "job-uuid-xxxx",
  "status": "completed",
  "result": { ... },
  "output_files": ["https://s3.../output/file1.png"],
  "execution_time_ms": 1234
}

Response (202 Accepted) - 비동기 모드:
{
  "job_id": "job-uuid-xxxx",
  "status": "pending",
  "message": "Job submitted. Poll GET /status/{job_id} for results."
}

로직:
1. job_id (UUID) 생성
2. DynamoDB에서 function 메타데이터 조회
3. SQS에 메시지 발행:
   {
     "job_id": "job-uuid",
     "function_id": "func-uuid",
     "s3_key": "functions/xxx/code.zip",
     "runtime": "python3.9",
     "handler": "main.handler",
     "payload": { ... },
     "timeout": 300
   }
4. Redis Subscribe로 결과 대기 (채널: result:{job_id})
   - 타임아웃: 5분 (req.setTimeout(300000))
5. 결과 수신 시 응답 반환
```

##### `GET /status/:job_id` - 작업 상태 조회 (비동기용)
```
Response:
{
  "job_id": "job-uuid-xxxx",
  "status": "completed" | "running" | "failed",
  "result": { ... },
  "output_files": [...]
}
```

#### 2.4 주의사항
- **소켓 타임아웃**: `req.setTimeout(300000)` 필수 (기본 2분 → 5분)
- **ALB Idle Timeout**: Terraform에서 300초로 설정 필요
- **Health Check**: `/health` 엔드포인트 필수 (ALB가 체크함)
- **PM2 사용**: `pm2 start server.js --name controller` (프로세스 관리)

#### 2.5 배포 방법
```bash
# Controller EC2에서
cd /home/ubuntu
git clone <your-repo> nanogrid-controller
cd nanogrid-controller
npm install
pm2 start server.js --name controller
pm2 save
pm2 startup  # 재부팅 시 자동 시작
```

---

## 🏃 3. Data Plane Team (Worker Agent - Python)

### 📌 목표
SQS에서 작업을 수신하고, Docker 컨테이너에서 사용자 코드를 실행한 뒤, 결과를 Redis로 발행합니다.  
**가장 핵심적인 파트입니다.**

### 🔲 개발 작업

#### 3.1 Worker Agent 구조
```
/home/ubuntu/nanogrid-worker/
├── agent.py          # 메인 에이전트 (SQS Polling)
├── executor.py       # Docker 실행 로직
├── uploader.py       # S3 Output Binding
├── requirements.txt  # boto3, redis, docker, requests
└── Dockerfile        # (선택) Agent 자체 컨테이너화
```

#### 3.2 환경변수 (Terraform에서 자동 주입됨)
```bash
S3_CODE_BUCKET=nanogrid-code-bucket
S3_USER_DATA_BUCKET=nanogrid-user-data-xxxxxxxxxxxx
SQS_QUEUE_URL=https://sqs.ap-northeast-2.amazonaws.com/xxx/nanogrid-task-queue
REDIS_HOST=nanogrid-redis.xxx.cache.amazonaws.com
REDIS_PORT=6379
AI_ENDPOINT=http://10.0.20.100:11434
```

#### 3.3 agent.py - 메인 루프
```python
import boto3
import redis
import json
import os
from executor import run_container
from uploader import upload_outputs

sqs = boto3.client('sqs')
redis_client = redis.Redis(
    host=os.environ['REDIS_HOST'],
    port=int(os.environ['REDIS_PORT'])
)

QUEUE_URL = os.environ['SQS_QUEUE_URL']

def poll_and_execute():
    while True:
        # 1. SQS에서 메시지 수신 (Long Polling)
        response = sqs.receive_message(
            QueueUrl=QUEUE_URL,
            MaxNumberOfMessages=1,
            WaitTimeSeconds=20,  # Long Polling
            VisibilityTimeout=300  # 5분 동안 다른 Worker가 못 가져감
        )
        
        messages = response.get('Messages', [])
        if not messages:
            continue
            
        for msg in messages:
            body = json.loads(msg['Body'])
            job_id = body['job_id']
            
            try:
                # 2. Docker 컨테이너 실행
                result = run_container(body)
                
                # 3. Output 파일 S3 업로드
                output_files = upload_outputs(job_id)
                
                # 4. 결과를 Redis로 발행
                result_payload = {
                    'job_id': job_id,
                    'status': 'completed',
                    'result': result,
                    'output_files': output_files
                }
                redis_client.publish(f'result:{job_id}', json.dumps(result_payload))
                
            except Exception as e:
                # 실패 시에도 Redis로 에러 발행
                error_payload = {
                    'job_id': job_id,
                    'status': 'failed',
                    'error': str(e)
                }
                redis_client.publish(f'result:{job_id}', json.dumps(error_payload))
            
            finally:
                # 5. SQS 메시지 삭제
                sqs.delete_message(
                    QueueUrl=QUEUE_URL,
                    ReceiptHandle=msg['ReceiptHandle']
                )

if __name__ == '__main__':
    print("Worker Agent started...")
    poll_and_execute()
```

#### 3.4 executor.py - Docker 실행
```python
import docker
import boto3
import os
import tempfile
import zipfile

s3 = boto3.client('s3')
docker_client = docker.from_env()

def run_container(job: dict) -> dict:
    job_id = job['job_id']
    s3_key = job['s3_key']
    runtime = job['runtime']
    handler = job['handler']
    payload = job.get('payload', {})
    timeout = job.get('timeout', 300)
    
    # 1. S3에서 코드 다운로드
    with tempfile.TemporaryDirectory() as tmpdir:
        code_path = os.path.join(tmpdir, 'code.zip')
        s3.download_file(os.environ['S3_CODE_BUCKET'], s3_key, code_path)
        
        # 압축 해제
        extract_path = os.path.join(tmpdir, 'code')
        with zipfile.ZipFile(code_path, 'r') as zip_ref:
            zip_ref.extractall(extract_path)
        
        # 2. Output 디렉토리 생성
        output_path = f'/tmp/output/{job_id}'
        os.makedirs(output_path, exist_ok=True)
        
        # 3. Docker 이미지 선택
        image = get_runtime_image(runtime)
        
        # 4. 환경변수 설정 (AI_ENDPOINT 포함!)
        environment = {
            'PAYLOAD': json.dumps(payload),
            'HANDLER': handler,
            'AI_ENDPOINT': os.environ['AI_ENDPOINT'],  # 중요!
            'JOB_ID': job_id
        }
        
        # 5. 볼륨 마운트 설정
        volumes = {
            extract_path: {'bind': '/code', 'mode': 'ro'},
            output_path: {'bind': '/output', 'mode': 'rw'}  # Output Binding
        }
        
        # 6. 컨테이너 실행
        container = docker_client.containers.run(
            image=image,
            command=f'python /code/{handler.replace(".", "/")}.py',
            environment=environment,
            volumes=volumes,
            detach=True,
            mem_limit='512m',
            cpu_period=100000,
            cpu_quota=50000,  # 0.5 CPU
            network_mode='bridge'  # AI Node 접근 가능
        )
        
        # 7. 결과 대기
        result = container.wait(timeout=timeout)
        logs = container.logs().decode('utf-8')
        
        # 8. 컨테이너 정리
        container.remove()
        
        return {
            'exit_code': result['StatusCode'],
            'logs': logs
        }

def get_runtime_image(runtime: str) -> str:
    """런타임에 맞는 Docker 이미지 반환"""
    images = {
        'python3.9': 'nanogrid/python:3.9-fat',
        'python3.10': 'nanogrid/python:3.10-fat',
        'python3.11': 'nanogrid/python:3.11-fat',
        'nodejs18.x': 'nanogrid/node:18-fat'
    }
    return images.get(runtime, 'nanogrid/python:3.9-fat')
```

#### 3.5 uploader.py - Output Binding (S3 업로드)
```python
import boto3
import os
from typing import List

s3 = boto3.client('s3')
BUCKET = os.environ['S3_USER_DATA_BUCKET']

def upload_outputs(job_id: str) -> List[str]:
    """
    /tmp/output/{job_id} 폴더의 모든 파일을 S3에 업로드하고
    URL 리스트를 반환합니다.
    """
    output_path = f'/tmp/output/{job_id}'
    uploaded_urls = []
    
    if not os.path.exists(output_path):
        return uploaded_urls
    
    for filename in os.listdir(output_path):
        filepath = os.path.join(output_path, filename)
        if os.path.isfile(filepath):
            s3_key = f'outputs/{job_id}/{filename}'
            
            # S3 업로드
            s3.upload_file(filepath, BUCKET, s3_key)
            
            # URL 생성 (Public 또는 Presigned)
            url = f'https://{BUCKET}.s3.ap-northeast-2.amazonaws.com/{s3_key}'
            uploaded_urls.append(url)
    
    # 로컬 파일 정리
    import shutil
    shutil.rmtree(output_path, ignore_errors=True)
    
    return uploaded_urls
```

#### 3.6 Docker 이미지 빌드 (Fat Image)

사용자 코드에서 자주 쓰는 라이브러리를 미리 포함한 이미지를 빌드합니다.

```dockerfile
# Dockerfile.python-fat
FROM python:3.9-slim

# 자주 사용되는 패키지 사전 설치
RUN pip install --no-cache-dir \
    requests \
    numpy \
    pandas \
    pillow \
    boto3 \
    httpx

# 작업 디렉토리
WORKDIR /code

# Output 디렉토리
RUN mkdir -p /output
```

```bash
# 빌드 및 푸시
docker build -t nanogrid/python:3.9-fat -f Dockerfile.python-fat .
# ECR 또는 Docker Hub에 푸시
```

#### 3.7 Worker 배포 (systemd 서비스)
```bash
# /etc/systemd/system/nanogrid-worker.service
[Unit]
Description=NanoGrid Worker Agent
After=network.target docker.service

[Service]
Type=simple
User=ubuntu
WorkingDirectory=/home/ubuntu/nanogrid-worker
ExecStart=/usr/bin/python3 agent.py
Restart=always
RestartSec=10
Environment="PATH=/usr/local/bin:/usr/bin"

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable nanogrid-worker
sudo systemctl start nanogrid-worker
```

---

## 🧠 4. AI Node Team

### 📌 목표
EC2 부팅 시 Ollama LLM 서버가 자동으로 준비되도록 합니다.  
Worker에서 `AI_ENDPOINT` 환경변수로 접근합니다.

### ✅ 완료된 작업 (Terraform)
- [x] AI Node EC2 생성 (t3.large, Private-Data Subnet)
- [x] 고정 IP 할당: `10.0.20.100`
- [x] Security Group: Worker SG에서만 11434 포트 접근 허용
- [x] User Data 스크립트 (Docker + Ollama 자동 설치)

### 🔲 추가 작업

#### 4.1 User Data 스크립트 (현재 Terraform에 포함됨)
```bash
#!/bin/bash
set -e

# Docker 설치
apt-get update
apt-get install -y docker.io
systemctl start docker
systemctl enable docker

# Ollama 컨테이너 실행
docker run -d \
  --name ollama \
  --restart always \
  -p 11434:11434 \
  -e OLLAMA_HOST=0.0.0.0 \
  ollama/ollama

# 컨테이너 준비 대기
sleep 30

# 모델 사전 다운로드 (Cold Start 방지)
docker exec ollama ollama pull llama3:8b
```

#### 4.2 수동 모델 관리 (SSH 접속 필요)
```bash
# AI Node는 Private Subnet이므로 Bastion 또는 Session Manager 필요
# Controller EC2를 Bastion으로 사용 가능

# Controller에서 AI Node로 SSH (같은 VPC)
ssh -i key.pem ubuntu@10.0.20.100

# 모델 목록 확인
docker exec ollama ollama list

# 추가 모델 다운로드
docker exec ollama ollama pull phi3:mini      # 가벼운 모델
docker exec ollama ollama pull codellama:7b   # 코드 특화
docker exec ollama ollama pull mistral:7b     # 범용

# 모델 삭제 (디스크 공간 확보)
docker exec ollama ollama rm llama3:8b
```

#### 4.3 Ollama API 사용법 (Worker/사용자 코드에서)
```python
import requests
import os

AI_ENDPOINT = os.environ.get('AI_ENDPOINT', 'http://10.0.20.100:11434')

def generate_text(prompt: str, model: str = 'llama3:8b') -> str:
    """텍스트 생성"""
    response = requests.post(
        f'{AI_ENDPOINT}/api/generate',
        json={
            'model': model,
            'prompt': prompt,
            'stream': False
        },
        timeout=120
    )
    return response.json()['response']

def chat(messages: list, model: str = 'llama3:8b') -> str:
    """대화형 API"""
    response = requests.post(
        f'{AI_ENDPOINT}/api/chat',
        json={
            'model': model,
            'messages': messages,
            'stream': False
        },
        timeout=120
    )
    return response.json()['message']['content']

# 사용 예시
result = generate_text("Python으로 피보나치 함수를 작성해줘")
print(result)
```

#### 4.4 모델 권장 사양
| 모델 | 크기 | 메모리 | 용도 | 인스턴스 |
|------|------|--------|------|----------|
| phi3:mini | 2.3GB | 4GB | 가벼운 작업 | t3.medium |
| llama3:8b | 4.7GB | 8GB | 범용 | t3.large |
| codellama:7b | 3.8GB | 8GB | 코드 생성 | t3.large |
| mistral:7b | 4.1GB | 8GB | 범용 | t3.large |
| llama3:70b | 40GB | 48GB+ | 고품질 | g4dn.xlarge |

#### 4.5 헬스체크 및 모니터링
```bash
# Ollama 상태 확인
curl http://10.0.20.100:11434/api/tags

# 응답 예시
{
  "models": [
    {"name": "llama3:8b", "size": 4661224676, ...}
  ]
}
```

#### 4.6 비용 최적화 (선택)
AI Node를 항상 켜두면 비용이 발생합니다. 사용량이 적다면:
- **Spot Instance**: 70% 비용 절감 (중단 가능성 있음)
- **스케줄링**: Lambda로 업무 시간에만 Start/Stop
- **제거**: AI 기능이 필요 없으면 Terraform에서 주석 처리

---

## 💻 5. Demo / Frontend Team

### 📌 목표
모든 기능이 정상 동작하는지 검증할 데모 시나리오와 코드를 작성합니다.

### 🔲 개발 작업

#### 5.1 테스트 시나리오

| # | 시나리오 | 검증 항목 |
|---|----------|-----------|
| 1 | 기본 실행 | Upload → Run → 결과 반환 |
| 2 | AI 연동 | AI_ENDPOINT로 LLM 호출 |
| 3 | Output Binding | /output 폴더 → S3 자동 업로드 |
| 4 | 비동기 모드 | X-Async 헤더로 202 반환 |
| 5 | 타임아웃 | 5분 이상 작업 처리 |
| 6 | 에러 처리 | 실패 시 에러 메시지 반환 |

#### 5.2 데모 1: Hello World (기본 동작 확인)

**hello.py:**
```python
import json
import os

def handler(event, context):
    payload = json.loads(os.environ.get('PAYLOAD', '{}'))
    name = payload.get('name', 'World')
    return {
        'statusCode': 200,
        'body': f'Hello, {name}!'
    }

if __name__ == '__main__':
    result = handler(None, None)
    print(json.dumps(result))
```

**테스트:**
```bash
# 1. 업로드
curl -X POST http://<ALB_DNS>/upload \
  -F "file=@hello.py" \
  -F "function_name=hello" \
  -F "runtime=python3.9" \
  -F "handler=hello.handler"

# 응답: {"function_id": "abc-123", ...}

# 2. 실행
curl -X POST http://<ALB_DNS>/run \
  -H "Content-Type: application/json" \
  -d '{"function_id": "abc-123", "payload": {"name": "NanoGrid"}}'

# 응답: {"status": "completed", "result": {"body": "Hello, NanoGrid!"}}
```

#### 5.3 데모 2: AI 요약 봇 (AI Node 연동)

**summarizer.py:**
```python
import json
import os
import requests

def handler(event, context):
    payload = json.loads(os.environ.get('PAYLOAD', '{}'))
    text = payload.get('text', '')
    
    if not text:
        return {'error': 'text is required'}
    
    # AI Node 호출
    ai_endpoint = os.environ.get('AI_ENDPOINT', 'http://10.0.20.100:11434')
    
    response = requests.post(
        f'{ai_endpoint}/api/generate',
        json={
            'model': 'llama3:8b',
            'prompt': f'다음 텍스트를 3줄로 요약해줘:\n\n{text}',
            'stream': False
        },
        timeout=120
    )
    
    summary = response.json()['response']
    
    return {
        'statusCode': 200,
        'original_length': len(text),
        'summary': summary
    }

if __name__ == '__main__':
    result = handler(None, None)
    print(json.dumps(result, ensure_ascii=False))
```

**테스트:**
```bash
curl -X POST http://<ALB_DNS>/run \
  -H "Content-Type: application/json" \
  -d '{
    "function_id": "summarizer-id",
    "payload": {
      "text": "인공지능(AI)은 인간의 학습능력, 추론능력, 지각능력을 인공적으로 구현한 컴퓨터 시스템입니다. 머신러닝, 딥러닝 등의 기술을 통해 발전하고 있으며, 자연어 처리, 이미지 인식, 자율주행 등 다양한 분야에서 활용되고 있습니다."
    }
  }'
```

#### 5.4 데모 3: 이미지 처리 (Output Binding)

**image_processor.py:**
```python
import json
import os
from PIL import Image
import io
import base64

def handler(event, context):
    payload = json.loads(os.environ.get('PAYLOAD', '{}'))
    
    # Base64 이미지 디코딩
    image_b64 = payload.get('image_base64', '')
    width = payload.get('width', 200)
    height = payload.get('height', 200)
    
    if not image_b64:
        return {'error': 'image_base64 is required'}
    
    # 이미지 처리
    image_data = base64.b64decode(image_b64)
    image = Image.open(io.BytesIO(image_data))
    
    # 리사이즈
    resized = image.resize((width, height))
    
    # /output 폴더에 저장 (Output Binding)
    output_path = '/output/resized.png'
    resized.save(output_path)
    
    return {
        'statusCode': 200,
        'message': 'Image resized and saved to /output',
        'original_size': image.size,
        'new_size': (width, height)
    }

if __name__ == '__main__':
    result = handler(None, None)
    print(json.dumps(result))
```

**테스트:**
```bash
# 이미지를 Base64로 인코딩
IMAGE_B64=$(base64 -i sample.png)

curl -X POST http://<ALB_DNS>/run \
  -H "Content-Type: application/json" \
  -d "{
    \"function_id\": \"image-processor-id\",
    \"payload\": {
      \"image_base64\": \"$IMAGE_B64\",
      \"width\": 100,
      \"height\": 100
    }
  }"

# 응답에 output_files 필드 확인
# {"output_files": ["https://nanogrid-user-data-xxx.s3.../outputs/job-id/resized.png"]}
```

#### 5.5 데모 4: 비동기 실행

```bash
# X-Async 헤더 추가
curl -X POST http://<ALB_DNS>/run \
  -H "Content-Type: application/json" \
  -H "X-Async: true" \
  -d '{"function_id": "long-running-id", "payload": {}}'

# 즉시 응답 (202 Accepted)
# {"job_id": "job-xxx", "status": "pending"}

# 나중에 상태 확인
curl http://<ALB_DNS>/status/job-xxx
```

#### 5.6 E2E 테스트 스크립트

**test_e2e.sh:**
```bash
#!/bin/bash
set -e

ALB_DNS="nanogrid-alb-xxx.ap-northeast-2.elb.amazonaws.com"
BASE_URL="http://$ALB_DNS"

echo "=== NanoGrid E2E Test ==="

# 1. Health Check
echo "[1/5] Health Check..."
curl -s "$BASE_URL/health" | jq .

# 2. Upload Function
echo "[2/5] Uploading function..."
UPLOAD_RESULT=$(curl -s -X POST "$BASE_URL/upload" \
  -F "file=@hello.py" \
  -F "function_name=test-hello" \
  -F "runtime=python3.9" \
  -F "handler=hello.handler")
echo $UPLOAD_RESULT | jq .
FUNC_ID=$(echo $UPLOAD_RESULT | jq -r '.function_id')

# 3. Run Function (Sync)
echo "[3/5] Running function (sync)..."
curl -s -X POST "$BASE_URL/run" \
  -H "Content-Type: application/json" \
  -d "{\"function_id\": \"$FUNC_ID\", \"payload\": {\"name\": \"Test\"}}" | jq .

# 4. Run Function (Async)
echo "[4/5] Running function (async)..."
ASYNC_RESULT=$(curl -s -X POST "$BASE_URL/run" \
  -H "Content-Type: application/json" \
  -H "X-Async: true" \
  -d "{\"function_id\": \"$FUNC_ID\", \"payload\": {}}")
echo $ASYNC_RESULT | jq .
JOB_ID=$(echo $ASYNC_RESULT | jq -r '.job_id')

# 5. Check Status
echo "[5/5] Checking status..."
sleep 5
curl -s "$BASE_URL/status/$JOB_ID" | jq .

echo "=== Test Complete ==="
```

---

## 📊 6. 전체 아키텍처 요약

### 데이터 흐름
```
User Request
    │
    ▼
┌─────────────────┐
│  ALB (Multi-AZ) │  ← Public Subnet 1,2
└────────┬────────┘
         │ HTTP :80
         ▼
┌─────────────────┐
│  Controller EC2 │  ← Public Subnet 1 (10.0.1.84)
│  (Express.js)   │
└────────┬────────┘
         │
    ┌────┴────┬──────────────┐
    │         │              │
    ▼         ▼              ▼
┌───────┐ ┌───────┐    ┌──────────┐
│  SQS  │ │ Redis │    │ DynamoDB │
└───┬───┘ └───┬───┘    └──────────┘
    │         │
    │         │ Subscribe (결과 대기)
    │         │
    ▼         │
┌─────────────────┐
│  Worker EC2     │  ← Private-Data Subnet (ASG)
│  (Python Agent) │
└────────┬────────┘
         │
    ┌────┴────┐
    │         │
    ▼         ▼
┌───────┐ ┌───────────┐
│  S3   │ │  AI Node  │  ← 10.0.20.100:11434
│(Output)│ │ (Ollama)  │
└───────┘ └───────────┘
```

### 포트 매트릭스
| From | To | Port | Protocol | 용도 |
|------|-----|------|----------|------|
| Internet | ALB | 80, 443 | HTTP/S | 외부 접근 |
| ALB | Controller | 80 | HTTP | 트래픽 포워딩 |
| Controller | Redis | 6379 | TCP | Pub/Sub |
| Controller | SQS | 443 | HTTPS | 작업 발행 |
| Worker | SQS | 443 | HTTPS | 작업 수신 |
| Worker | Redis | 6379 | TCP | 결과 발행 |
| Worker | AI Node | 11434 | HTTP | LLM 호출 |
| Worker | S3 | 443 | HTTPS | 코드/결과 |

### 환경변수 정리
| 변수 | Controller | Worker | 값 |
|------|------------|--------|-----|
| S3_BUCKET | ✅ | - | nanogrid-code-bucket |
| S3_CODE_BUCKET | - | ✅ | nanogrid-code-bucket |
| S3_USER_DATA_BUCKET | - | ✅ | nanogrid-user-data-xxx |
| DYNAMODB_TABLE | ✅ | - | NanoGridFunctions |
| SQS_QUEUE_URL | ✅ | ✅ | https://sqs.../nanogrid-task-queue |
| REDIS_HOST | ✅ | ✅ | nanogrid-redis.xxx.cache.amazonaws.com |
| REDIS_PORT | ✅ | ✅ | 6379 |
| AI_ENDPOINT | - | ✅ | http://10.0.20.100:11434 |

---

## ✅ 체크리스트

### Infrastructure (Terraform)
- [x] VPC, Subnet, NAT Gateway
- [x] ALB + Target Group + Listener
- [x] Controller EC2 (Public Subnet)
- [x] Worker ASG (Private Subnet)
- [x] AI Node EC2 (Private Subnet, 고정 IP)
- [x] Security Groups
- [x] IAM Roles & Policies
- [x] S3 Buckets (code, user-data)
- [x] ElastiCache Redis
- [x] CloudWatch Alarms (Auto Scaling)
- [ ] HTTPS (ACM + ALB Listener)
- [ ] Route53 도메인

### Backend (Controller)
- [ ] Express 서버 기본 구조
- [ ] GET /health
- [ ] POST /upload
- [ ] POST /run (동기)
- [ ] POST /run (비동기, X-Async)
- [ ] GET /status/:job_id
- [ ] PM2 배포

### Data Plane (Worker)
- [ ] agent.py (SQS Polling)
- [ ] executor.py (Docker 실행)
- [ ] uploader.py (Output Binding)
- [ ] Fat Docker Image 빌드
- [ ] systemd 서비스 등록

### AI Node
- [x] EC2 + Docker + Ollama (Terraform user_data)
- [ ] 모델 다운로드 확인 (llama3:8b)
- [ ] 헬스체크 확인

### Demo
- [ ] hello.py (기본 동작)
- [ ] summarizer.py (AI 연동)
- [ ] image_processor.py (Output Binding)
- [ ] E2E 테스트 스크립트

---

## 📞 담당자 연락처

| 파트 | 담당자 | 역할 |
|------|--------|------|
| Infrastructure | TBD | Terraform, AWS 리소스 |
| Backend | TBD | Controller Express.js |
| Data Plane | TBD | Worker Agent, Docker |
| AI Node | TBD | Ollama, 모델 관리 |
| Demo/QA | TBD | 테스트, 문서화 |
