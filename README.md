# NanoGrid - Self-Hosted AI FaaS Platform

Lambda 없이 EC2 위에 직접 구현한 Self-Hosted AI FaaS 플랫폼

## 아키텍처 개요

```
User → WAF → ALB → Controller EC2 (Multi-AZ)
                        ↓
                   DynamoDB (메타데이터)
                        ↓
                   SQS (작업 큐)
                        ↓
              Worker EC2 (Private Subnet, ASG)
                 ↓              ↓              ↓
            AI Node         Redis          S3/GCP
         (Private AI)    (상태 관리)    (영속 저장)
```

## 주요 특징

- **Lambda-less**: EC2 Controller로 타임아웃 제한 없는 장기 실행 지원
- **Private AI**: VPC 내부 격리된 AI 추론 서버 (Ollama)
- **Auto Scaling**: SQS 메시지 기반 Worker 자동 확장 (2~5대)
- **Multi-AZ**: 고가용성을 위한 다중 가용영역 배치
- **멀티클라우드**: AWS S3 + GCP Cloud Storage 데이터 영속성

## 인프라 구성

| 구성요소 | 스펙 | 개수 |
|----------|------|------|
| Controller | t3.small | 2대 (Multi-AZ) |
| Worker | t3.small | 2~5대 (ASG) |
| AI Node | t3.large | 1대 |
| Redis | cache.t3.micro | 1대 |

## 네트워크

| Subnet | CIDR | 용도 |
|--------|------|------|
| Public 1 | 10.0.1.0/24 | ALB, NAT Gateway (AZ-a) |
| Public 2 | 10.0.2.0/24 | ALB (AZ-c) |
| Private Data 1 | 10.0.20.0/24 | Worker, Redis, AI Node (AZ-a) |
| Private Data 2 | 10.0.21.0/24 | Worker (AZ-c) |

## Auto Scaling 설정

| 설정 | 값 |
|------|-----|
| Min Size | 2 |
| Max Size | 5 |
| Scale Out | SQS 메시지 ≥ 10개 |
| Scale In | SQS 메시지 = 0개 |
| Cooldown | 300초 |

## 사용 기술

- **IaC**: Terraform
- **언어**: Node.js (Controller), Python (Worker)
- **AWS**: EC2, VPC, ALB, SQS, S3, ElastiCache, Secrets Manager, CloudWatch
- **GCP**: Cloud Storage
- **보안**: AWS WAF, Private Subnet, Security Group
- **AI**: Ollama (Self-hosted)

## 배포

```bash
# Terraform 초기화
terraform init

# 변경사항 확인
terraform plan

# 적용
terraform apply
```

## 주요 엔드포인트

| 서비스 | 엔드포인트 |
|--------|-----------|
| ALB | nanogrid-alb-xxx.ap-northeast-2.elb.amazonaws.com |
| Redis | nanogrid-redis.xxx.cache.amazonaws.com:6379 |
| AI Node | 10.0.20.100:11434 (Private) |
| SQS | https://sqs.ap-northeast-2.amazonaws.com/xxx/nanogrid-task-queue |

## 관련 문서

- [Worker 요구사항](WORKER_REQUIREMENTS.md)
- [Auto Scaling 설정](AUTOSCALING_SETUP.md)
- [GCP 연동 가이드](GCP_INTEGRATION_GUIDE.md)
- [발표 요약](PRESENTATION_SUMMARY.md)
