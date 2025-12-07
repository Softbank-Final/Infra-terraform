# SQS 기반 Auto Scaling 설정

## 개요

Worker EC2 인스턴스가 SQS 대기열 깊이(Queue Depth)를 기반으로 자동 확장/축소되도록 설정

---

## 현재 설정

### Auto Scaling Group

| 설정 | 값 |
|------|-----|
| ASG 이름 | `nanogrid-worker-asg` |
| Min Size | 1 |
| **Desired Capacity** | **2** |
| Max Size | 5 |
| Subnet (Multi-AZ) | ap-northeast-2a, ap-northeast-2c |

### CloudWatch Alarms

| Alarm | 조건 | 동작 | Cooldown |
|-------|------|------|----------|
| `nanogrid-sqs-high` | 메시지 ≥ **5개** | Worker +1 (Scale Out) | 300초 |
| `nanogrid-sqs-low` | 메시지 = 0개 | Worker -1 (Scale In) | 300초 |

---

## 변경 이력

### 2025-12-07

1. **worker-test 종료 및 ASG 통합**
   - 기존 `nanogrid-worker-test` (수동 관리) 종료
   - ASG `desired_capacity`를 2로 변경
   - 모든 Worker가 ASG로 통합 관리됨

2. **Auto Scaling 임계값 변경**
   - Scale Out 임계값: 10개 → **5개**
   - Cooldown: 60초/120초 → **300초** (5분)

3. **Multi-AZ 분산 배치**
   - Worker 2대가 ap-northeast-2a, ap-northeast-2c에 분산 배치됨

---

## 현재 Worker 인스턴스

| Instance ID | AZ | 상태 |
|-------------|-----|------|
| `i-04e8f5de9c1d9f1c0` | ap-northeast-2c | running |
| (새로 생성됨) | ap-northeast-2a | running |

---

## 동작 흐름

```
1. Controller가 SQS에 메시지 전송
2. CloudWatch가 SQS 메시지 수 모니터링
3. 메시지 ≥ 5개 → sqs_high 알람 발생 → Worker +1
4. 메시지 = 0개 (3분 유지) → sqs_low 알람 발생 → Worker -1
5. Worker는 항상 최소 1대, 최대 5대 유지
```

---

## 관련 Terraform 리소스

```hcl
# variables.tf
variable "asg_desired_capacity" {
  default = 2
}

# main.tf
resource "aws_autoscaling_group" "worker_asg" {
  desired_capacity    = var.asg_desired_capacity  # 2
  min_size            = var.asg_min_size          # 1
  max_size            = var.asg_max_size          # 5
  vpc_zone_identifier = [aws_subnet.private_data.id, aws_subnet.private_data_2.id]
}

resource "aws_cloudwatch_metric_alarm" "sqs_high" {
  threshold = 5  # 메시지 5개 이상
}

resource "aws_autoscaling_policy" "scale_out" {
  cooldown = 300  # 5분
}
```

---

## 수동 조작 명령어

```bash
# Worker 수 조회
aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names nanogrid-worker-asg \
  --query "AutoScalingGroups[0].{Desired:DesiredCapacity,Min:MinSize,Max:MaxSize,Running:length(Instances)}"

# Worker 수 수동 변경
aws autoscaling set-desired-capacity \
  --auto-scaling-group-name nanogrid-worker-asg \
  --desired-capacity 3

# Instance Refresh (새 Launch Template 적용)
aws autoscaling start-instance-refresh \
  --auto-scaling-group-name nanogrid-worker-asg
```
