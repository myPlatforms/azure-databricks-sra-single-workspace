# Azure Databricks 단일 워크스페이스 SRA · 사설 PostgreSQL CDC · OpenSharing D2D — Terraform 예제 (비공식)

Azure Databricks에서 아래 구성을 Terraform으로 배포하는 **비공식 예제**와 한국어 구성 가이드입니다.

- **1단계**: 리전마다 단일 워크스페이스 SRA(Security Reference Architecture) 원칙의 워크스페이스. 프런트엔드만 공개, 백엔드·스토리지는 사설. 별도 VNet의 사설 PostgreSQL을 Lakeflow Connect PostgreSQL CDC(Standard, Gateway 방식)로 수집
- **2단계**: OpenSharing Databricks-to-Databricks로 리전 간 공유. 제공자 스토리지는 사설 상태로 두고 SecureConnect가 중개
- **부록 A**: 수신자 리전에서 제공자 리전의 사설 PostgreSQL로 조회·쓰기 (전 구간 사설 경로)

👉 **[구성 가이드](docs/Azure_SRA_OpenSharing_Configuration_Guide.md)를 먼저 읽고, "0.5 전체 실행 순서"를 따라 실행합니다.**

## 고지

- Databricks의 공식 프로젝트가 아닙니다. 공식 SRA Terraform([databricks/terraform-databricks-sra](https://github.com/databricks/terraform-databricks-sra))은 Hub-Spoke를 전제로 하며, 이 예제는 **Hub 없는 단일 워크스페이스**에 공식 SRA의 워크스페이스 보안 설정 일부를 옮긴 구성입니다(차이는 가이드 부록 D).
- 학습·참고용으로 **있는 그대로** 제공되며 지원(SLA)이나 보증이 없습니다. 이 예제와 관련해 Databricks에 지원 티켓을 제출하지 마세요.
- 운영 환경에 적용하기 전에 조직의 보안·네트워크 기준에 맞게 검토하고 수정합니다. 제품 상태(GA·Preview)와 제약은 가이드 기준일(2026-11-12)의 Microsoft Learn 문서를 따르며, 이후 바뀔 수 있습니다.
- 공식 SRA 문서의 한국어 번역(비공식): [myPlatforms/databricks-sra-ko](https://github.com/myPlatforms/databricks-sra-ko) · [사이트](https://myplatforms.github.io/databricks-sra-ko/)

## 구성

```
docs/                          구성 가이드(md), 구성도(svg)
modules/
  azure-databricks-hardened/   워크스페이스 공통 모듈 (VNet, PE, NCC, 네트워크 정책, 전용 메타스토어, PNG)
envs/
  sra-provider/                제공자 리전 워크스페이스
  sra-recipient/               수신자 리전 워크스페이스 (sra-provider와 같은 코드, 값만 다름)
  pg-source/                   샘플 원천: 사설 PostgreSQL Flexible Server + 원천 VNet + 피어링 + Private DNS
  pg-png-access/               PostgreSQL NSG에 제공자 PNG 서브넷 허용 규칙 1개
  lfc-pg-cdc/                  Lakeflow Connect PostgreSQL CDC (Standard: Gateway + 수집 파이프라인)
  opensharing/                 OpenSharing NCC·PE, share, recipient, 수신 카탈로그
  recipient-pg-access/         부록 A: 수신자 → 제공자 리전 PostgreSQL (피어링, DNS 링크, NSG, UC 연결, 쓰기 Job)
samples/
  adventureworks-pg/           샘플 데이터 적재 + 원천 설정 노트북 (pg-source를 쓸 때만)
  opensharing/                 공유 데이터 준비 노트북, PostgreSQL 쓰기 노트북
```

## 사용 방법 (요약)

1. 각 `envs/<stack>`에서 `terraform.tfvars.example`을 `terraform.tfvars`로 복사해 값을 채웁니다.
2. `terraform init` → `terraform plan -out tfplan` → `terraform apply tfplan`
3. 스택끼리는 `terraform_remote_state`로 출력값을 받습니다(기본 경로 `../<stack>/terraform.tfstate`).

이미 있는 PostgreSQL을 쓰면 `pg-source`는 건너뛰고, 다른 스택의 `pg_state_path = null`과 `pg_*` 변수로 접속 정보와 네트워크 객체 이름을 넘깁니다(각 `terraform.tfvars.example` 참고).

## 주의

- **state·tfvars·plan 파일에는 비밀번호와 식별자가 평문으로 들어갑니다.** 커밋하지 말고(`.gitignore` 참고), 운영에서는 접근을 제한한 원격 backend(azurerm)에 둡니다. 예제의 `backend.tf`는 local입니다.
- Provider lock 파일(`.terraform.lock.hcl`)은 넣지 않았습니다. `terraform init`이 버전 제약(`azurerm ~> 5.12`, `databricks ~> 1.141`) 안에서 새로 만듭니다.
- NCC 사설 엔드포인트 승인 스크립트(`modules/azure-databricks-hardened/scripts/approve_private_endpoints.sh`)는 Terraform을 실행하는 곳의 Azure CLI(`az login`)와 bash를 씁니다. 이 스택이 만든 엔드포인트의 연결만 승인합니다.
- 상시 과금 리소스(NAT Gateway, PE, PostgreSQL, PNG, LFC Gateway 등)가 있습니다. 정리 순서는 가이드 부록 B.4를 따릅니다.
- 샘플 데이터는 Microsoft [sql-server-samples](https://github.com/microsoft/sql-server-samples)의 AdventureWorks OLTP를 노트북 실행 시 내려받아 씁니다(이 리포에 데이터는 포함하지 않음).

## 라이선스

[Apache License 2.0](LICENSE)
