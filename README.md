# NanoGrid - Self-Hosted AI FaaS Platform - 고동현

> Lambda 없이 EC2 위에 직접 구현한 완전 자립형(Self-Hosted) AI FaaS 플랫폼

## 📋 목차

- [프로젝트 개요](#프로젝트-개요)
- [아키텍처](#아키텍처)
- [기술 스택](#기술-스택)
- [AWS 서비스 상세](#aws-서비스-상세)
- [네트워크 구성](#네트워크-구성)
- [보안 구성](#보안-구성)
- [Auto Scaling](#auto-scaling)
- [데이터 흐름](#데이터-흐름)
- [배포 가이드](#배포-가이드)
- [모니터링](#모니터링)

---

## 프로젝트 개요

### 아이디어
**"Lambda 없이 EC2 위에 직접 구현한 Self-Hosted AI FaaS 플랫폼"**

### 제작 배경

| 기존 문제점 | NanoGrid 해결책 |
|------------|----------------|
| Lambda 29초 타임아웃 한계 | EC2 Controller로 장기 실행 지원 |
| Vendor Lock-in (Bedrock, OpenAI 등) | VPC 내부 Private AI Node 구축 |
| 데이터 유출/보안 우려 | 모든 데이터가 VPC 내부에서만 처리 |
| VMware 탈피 니즈 | 경량 컨테이너 기반 자체 클라우드 엔진 |
| 확장성 부족 | SQS 기반 Auto Scaling으로 자동 확장 |

### 핵심 기능

- ✅ 타임아웃 제한 없는 무제한 함수 배포
- ✅ 외부 AI API 의존 없는 Private AI 추론
- ✅ 멀티클라우드 데이터 영속 저장 (AWS S3 + GCP Cloud Storage)
- ✅ SQS 기반 자동 확장/축소
- ✅ Multi-AZ 고가용성 아키텍처

---

## 아키텍처
<img width="1427" height="1501" alt="image" src="https://github.com/user-attachments/assets/fe3623e2-3c43-4bfd-84e0-3edb46ebee02" />


### 전체 아키텍처 다이어그램

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              Internet                                        │
└─────────────────────────────────┬───────────────────────────────────────────┘
                                  │
                                  ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                           AWS WAF                                            │
│         (SQLi, XSS, Log4j, Rate Limit 1000/5min, Size 1GB)                  │
└─────────────────────────────────┬───────────────────────────────────────────┘
                                  │
                                  ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                    Application Load Balancer (Multi-AZ)                      │
└───────────────────────┬─────────────────────────────┬───────────────────────┘
                        │                             │
                        ▼                             ▼
┌───────────────────────────────────┐   ┌───────────────────────────────────┐
│   Public Subnet (AZ-a)            │   │   Public Subnet (AZ-c)            │
│   10.0.1.0/24                     │   │   10.0.2.0/24                     │
│                                   │   │                                   │
│   ┌─────────────────────────┐     │   │   ┌─────────────────────────┐     │
│   │  Controller #1 (EC2)    │     │   │   │  Controller #2 (EC2)    │     │
│   │  t3.small               │     │   │   │  t3.small               │     │
│   │  Node.js/Express        │     │   │   │  Node.js/Express        │     │
│   └───────────┬─────────────┘     │   │   └───────────┬─────────────┘     │
│               │                   │   │               │                   │
│   ┌───────────┴─────────────┐     │   │               │                   │
│   │  NAT Gateway            │     │   │               │                   │
│   └─────────────────────────┘     │   │               │                   │
└───────────────┬───────────────────┘   └───────────────┼───────────────────┘
                │                                       │
                ▼                                       ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                         Regional Services                                    │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐    │
│  │   DynamoDB   │  │     SQS      │  │      S3      │  │   Secrets    │    │
│  │  NanoGrid-   │  │  task-queue  │  │ code-bucket  │  │   Manager    │    │
│  │  Functions   │  │              │  │ user-data    │  │  GCP Creds   │    │
│  └──────────────┘  └──────────────┘  └──────────────┘  └──────────────┘    │
└─────────────────────────────────────────────────────────────────────────────┘
                │                             │
                ▼                             ▼
┌───────────────────────────────────┐   ┌───────────────────────────────────┐
│   Private Subnet (AZ-a)           │   │   Private Subnet (AZ-c)           │
│   10.0.20.0/24                    │   │   10.0.21.0/24                    │
│                                   │   │                                   │
│   ┌─────────────────────────┐     │   │   ┌─────────────────────────┐     │
│   │  Worker EC2 (ASG)       │     │   │   │  Worker EC2 (ASG)       │     │
│   │  t3.small               │     │   │   │  t3.small               │     │
│   │  Python + Docker        │     │   │   │  Python + Docker        │     │
│   └───────────┬─────────────┘     │   │   └─────────────────────────┘     │
│               │                   │   │                                   │
│   ┌───────────┴─────────────┐     │   │                                   │
│   │  AI Node (EC2)          │     │   │                                   │
│   │  t3.large               │     │   │                                   │
│   │  Ollama (11434)         │     │   │                                   │
│   └─────────────────────────┘     │   │                                   │
│                                   │   │                                   │
│   ┌─────────────────────────┐     │   │                                   │
│   │  ElastiCache Redis      │     │   │                                   │
│   │  cache.t3.micro         │     │   │                                   │
│   └─────────────────────────┘     │   │                                   │
└───────────────────────────────────┘   └───────────────────────────────────┘
                │
                ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                        Google Cloud Platform                                 │
│   ┌──────────────────────────────────────────────────────────────────┐      │
│   │  Cloud Storage: nanogird_gcp_bucket (코드 영속 저장)              │      │
│   └──────────────────────────────────────────────────────────────────┘      │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 기술 스택

### Infrastructure as Code (IaC)

| 도구 | 버전 | 용도 |
|------|------|------|
| **Terraform** | >= 1.0 | 인프라 프로비저닝 및 관리 |
| **AWS Provider** | 6.23.0 | AWS 리소스 관리 |
| **Archive Provider** | 2.7.1 | Lambda 패키징 (백업용) |

### 백엔드

| 기술 | 용도 |
|------|------|
| **Node.js** | Controller 서버 런타임 |
| **Express.js** | REST API 프레임워크 |
| **Python 3** | Worker 에이전트 |
| **PM2** | Node.js 프로세스 매니저 |
| **Docker** | 컨테이너 기반 코드 실행 |

### AI/ML

| 기술 | 용도 |
|------|------|
| **Ollama** | Self-hosted LLM 추론 서버 |
| **Private AI Node** | VPC 내부 격리된 AI 서비스 |

### 데이터베이스 & 캐시

| 서비스 | 용도 |
|--------|------|
| **DynamoDB** | 함수 메타데이터 저장 |
| **ElastiCache Redis** | 작업 상태 관리, Pub/Sub |
| **S3** | 코드 및 결과물 저장 |

### 멀티클라우드

| 클라우드 | 서비스 | 용도 |
|----------|--------|------|
| **AWS** | S3 | 원본 코드 저장 |
| **GCP** | Cloud Storage | 실행 성공 코드 영구 보존 |

---

## AWS 서비스 상세

### 1. VPC (Virtual Private Cloud)

```hcl
VPC CIDR: 10.0.0.0/16
Region: ap-northeast-2 (Seoul)
```

| 리소스 | 이름 | 설명 |
|--------|------|------|
| VPC | nanogrid-vpc | 메인 VPC |
| Internet Gateway | nanogrid-igw | 인터넷 연결 |
| NAT Gateway | nanogrid-nat-gw | Private Subnet 아웃바운드 |
| VPC Endpoint (S3) | nanogrid-s3-endpoint | S3 직접 연결 (비용 절감) |
| VPC Endpoint (DynamoDB) | nanogrid-dynamodb-endpoint | DynamoDB 직접 연결 |

### 2. EC2 (Elastic Compute Cloud)

#### Controller EC2

| 항목 | 값 |
|------|-----|
| Instance Type | t3.small |
| AMI | ami-04fcc2023d6e37430 (Ubuntu) |
| 개수 | 2대 (Multi-AZ) |
| Subnet | Public Subnet |
| IAM Role | nanogrid_controller_role |

**Controller IAM 권한:**
- S3: PutObject, GetObject, DeleteObject
- DynamoDB: PutItem, GetItem, UpdateItem, Query, DeleteItem
- SQS: SendMessage, GetQueueAttributes

#### Worker EC2 (Auto Scaling Group)

| 항목 | 값 |
|------|-----|
| Instance Type | t3.small |
| AMI | ami-04fcc2023d6e37430 (Amazon Linux 2023) |
| Min/Max | 2 / 5 |
| Subnet | Private Subnet (Multi-AZ) |
| IAM Role | nanogrid_worker_role |

**Worker IAM 권한:**
- S3: GetObject (code-bucket), PutObject (user-data-bucket)
- SQS: ReceiveMessage, DeleteMessage, GetQueueAttributes
- DynamoDB: GetItem
- Secrets Manager: GetSecretValue (GCP credentials)

**Worker User Data 설치 패키지:**
```bash
# 시스템 패키지
docker, python3-pip, git

# Python 패키지
boto3, redis, docker, requests, google-cloud-storage
```

#### AI Node EC2

| 항목 | 값 |
|------|-----|
| Instance Type | t3.large |
| Subnet | Private Subnet |
| Port | 11434 (Ollama) |
| 접근 | Worker Security Group에서만 허용 |

### 3. Application Load Balancer (ALB)

| 항목 | 값 |
|------|-----|
| 이름 | nanogrid-alb |
| Type | Application (Layer 7) |
| Scheme | Internet-facing |
| Subnets | Public Subnet 1, 2 (Multi-AZ) |

**Target Group:**
- Protocol: HTTP
- Port: 8080
- Health Check: /health

**Listener:**
- Port 80 (HTTP) → Controller Target Group

### 4. SQS (Simple Queue Service)

| 항목 | 값 |
|------|-----|
| Queue Name | nanogrid-task-queue |
| Type | Standard Queue |
| 용도 | Controller → Worker 작업 전달 |

**메시지 포맷:**
```json
{
  "job_id": "uuid-xxxx",
  "function_id": "func-xxxx",
  "code": "print('hello')"
}
```

### 5. S3 (Simple Storage Service)

| 버킷 | 용도 |
|------|------|
| nanogrid-code-bucket | 사용자 업로드 코드 저장 |
| nanogrid-user-data-{account_id} | 실행 결과물 저장 |

**버전 관리:** user-data 버킷에 Versioning 활성화

### 6. DynamoDB

| 테이블 | 용도 |
|--------|------|
| NanoGridFunctions | 함수 메타데이터 |

**스키마:**
- Partition Key: functionId (String)
- Billing Mode: PAY_PER_REQUEST

### 7. ElastiCache (Redis)

| 항목 | 값 |
|------|-----|
| Cluster ID | nanogrid-redis |
| Engine | Redis 7.1 |
| Node Type | cache.t3.micro |
| Nodes | 1 |

**용도:**
- 작업 상태 관리 (PENDING → PROCESSING → SUCCESS/FAILED)
- Controller ↔ Worker Pub/Sub 통신
- TTL 24시간 자동 정리

### 8. Secrets Manager

| Secret Name | 용도 |
|-------------|------|
| nanogrid/gcp-credentials | GCP 서비스 계정 JSON 키 |

**Worker에서 사용:**
```bash
aws secretsmanager get-secret-value \
  --secret-id nanogrid/gcp-credentials \
  --query SecretString \
  --output text > /etc/ncp-test-465906-417c34e96c23.json
```

### 9. CloudWatch

**Metric Alarms:**

| Alarm | 조건 | 동작 |
|-------|------|------|
| nanogrid-sqs-high | SQS 메시지 ≥ 10개 | Scale Out (+1) |
| nanogrid-sqs-low | SQS 메시지 = 0개 (3분) | Scale In (-1) |

---

## 네트워크 구성

### Subnet 구성

| Subnet | CIDR | AZ | 용도 | 라우팅 |
|--------|------|-----|------|--------|
| Public 1 | 10.0.1.0/24 | ap-northeast-2a | Controller, NAT GW | IGW |
| Public 2 | 10.0.2.0/24 | ap-northeast-2c | Controller | IGW |
| Private App | 10.0.10.0/24 | ap-northeast-2a | (예약) | NAT GW |
| Private Data 1 | 10.0.20.0/24 | ap-northeast-2a | Worker, Redis, AI | NAT GW |
| Private Data 2 | 10.0.21.0/24 | ap-northeast-2c | Worker | NAT GW |

### Route Table

**Public Route Table:**
```
0.0.0.0/0 → Internet Gateway
```

**Private Route Table:**
```
0.0.0.0/0 → NAT Gateway
S3 → VPC Endpoint
DynamoDB → VPC Endpoint
```

---

## 보안 구성

### Security Groups

#### ALB Security Group (nanogrid-alb-sg)

| Type | Port | Source |
|------|------|--------|
| Inbound | 80 | 0.0.0.0/0 |
| Inbound | 443 | 0.0.0.0/0 |
| Outbound | All | 0.0.0.0/0 |

#### Controller Security Group (nanogrid-controller-sg)

| Type | Port | Source |
|------|------|--------|
| Inbound | 22 | 0.0.0.0/0 |
| Inbound | 8080 | ALB SG |
| Outbound | All | 0.0.0.0/0 |

#### Worker Security Group (nanogrid-worker-sg)

| Type | Port | Source |
|------|------|--------|
| Outbound | All | 0.0.0.0/0 |

#### AI Node Security Group (nanogrid-ai-sg)

| Type | Port | Source |
|------|------|--------|
| Inbound | 11434 | Worker SG |
| Inbound | 22 | Controller SG |
| Outbound | All | 0.0.0.0/0 |

#### Redis Security Group (nanogrid-redis-sg)

| Type | Port | Source |
|------|------|--------|
| Inbound | 6379 | Controller SG, Worker SG |

### AWS WAF

**적용 규칙:**

| Rule | 설명 |
|------|------|
| AWSManagedRulesSQLiRuleSet | SQL Injection 방어 |
| AWSManagedRulesCommonRuleSet | XSS, Path Traversal 방어 |
| AWSManagedRulesKnownBadInputsRuleSet | Log4j, 악성 입력값 방어 |
| RateLimitRule | IP당 5분에 1000 요청 제한 |
| SizeConstraintRule | Body 1GB 제한 (Zip Bomb 방어) |

---

## Auto Scaling

### ASG 설정

| 항목 | 값 |
|------|-----|
| ASG Name | nanogrid-worker-asg |
| Min Size | 2 |
| Desired Capacity | 2 |
| Max Size | 5 |
| Subnets | Private Data 1, 2 (Multi-AZ) |

### Scaling Policy

| Policy | 조건 | 동작 | Cooldown |
|--------|------|------|----------|
| Scale Out | SQS ≥ 10 메시지 | +1 인스턴스 | 300초 |
| Scale In | SQS = 0 메시지 (3분) | -1 인스턴스 | 300초 |

### 동작 흐름

```
1. Controller가 SQS에 메시지 전송
2. CloudWatch가 SQS 메시지 수 모니터링
3. 메시지 ≥ 10개 → sqs_high 알람 → Worker +1
4. 메시지 = 0개 (3분 유지) → sqs_low 알람 → Worker -1
5. Worker는 항상 최소 2대, 최대 5대 유지
```

---

## 데이터 흐름

### 1. 함수 등록 (Upload)

```
User → ALB → Controller
              ↓
         S3 (코드 업로드)
              ↓
         DynamoDB (메타데이터 저장)
              ↓
         Response (functionId)
```

### 2. 함수 실행 (Run)

```
User → ALB → Controller
              ↓
         DynamoDB (메타데이터 조회)
              ↓
         SQS (작업 등록)
              ↓
         Worker (SQS 폴링)
              ↓
         S3 (코드 다운로드)
              ↓
         Docker (코드 실행)
              ↓
         AI Node (AI 추론 - 필요시)
              ↓
         Redis (결과 저장)
              ↓
         GCP Storage (영속 저장 - SUCCESS 시)
              ↓
         Controller (Redis 구독)
              ↓
         Response (결과)
```

---

## 배포 가이드

### 사전 요구사항

- AWS CLI 설정
- Terraform >= 1.0
- AWS 계정 및 적절한 IAM 권한

### 배포 단계

```bash
# 1. 저장소 클론
git clone <repository-url>
cd nanogrid

# 2. Terraform 초기화
terraform init

# 3. 변경사항 확인
terraform plan

# 4. 인프라 배포
terraform apply

# 5. Worker 인스턴스 갱신 (필요시)
aws autoscaling start-instance-refresh \
  --auto-scaling-group-name nanogrid-worker-asg
```

### 환경 변수

**Worker 환경 변수 (자동 설정):**

| 변수 | 설명 |
|------|------|
| S3_CODE_BUCKET | 코드 저장 버킷 |
| S3_USER_DATA_BUCKET | 결과물 저장 버킷 |
| SQS_QUEUE_URL | 작업 큐 URL |
| REDIS_HOST | Redis 엔드포인트 |
| REDIS_PORT | 6379 |
| AI_ENDPOINT | http://10.0.20.100:11434 |
| GCP_BUCKET_NAME | nanogird_gcp_bucket |
| GOOGLE_APPLICATION_CREDENTIALS | /etc/ncp-test-465906-417c34e96c23.json |

---

## 모니터링

### CloudWatch Metrics

- SQS: ApproximateNumberOfMessagesVisible
- ASG: GroupDesiredCapacity, GroupInServiceInstances
- ALB: RequestCount, TargetResponseTime

### 로그 확인

```bash
# Controller 로그
pm2 logs controller

# Worker 로그
tail -f /var/log/worker.log
```

### 유용한 명령어

```bash
# ASG 상태 확인
aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names nanogrid-worker-asg \
  --query "AutoScalingGroups[0].{Min:MinSize,Desired:DesiredCapacity,Max:MaxSize,Running:length(Instances)}"

# SQS 메시지 수 확인
aws sqs get-queue-attributes \
  --queue-url <queue-url> \
  --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible

# Worker 수 수동 조정
aws autoscaling set-desired-capacity \
  --auto-scaling-group-name nanogrid-worker-asg \
  --desired-capacity 3
```

---

## 관련 문서

- [Worker 요구사항](WORKER_REQUIREMENTS.md)
- [Auto Scaling 설정](AUTOSCALING_SETUP.md)
- [GCP 연동 가이드](GCP_INTEGRATION_GUIDE.md)
- [발표 요약](PRESENTATION_SUMMARY.md)

---

## 라이선스

MIT License
