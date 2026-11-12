# Databricks notebook source
# MAGIC %md
# MAGIC # AdventureWorks → Azure Database for PostgreSQL (private) + Lakeflow Connect 소스 설정
# MAGIC
# MAGIC 이 노트북은 **클래식 컴퓨트(워크스페이스 VNet)** 에서 실행합니다. PostgreSQL Flexible Server는 공개 접근이 없고
# MAGIC 원천 VNet과 워크스페이스 VNet 사이의 피어링 + private DNS 영역으로만 닿습니다. 즉 이 노트북이 성공하면
# MAGIC Lakeflow Connect ingestion gateway(같은 VNet의 클래식 컴퓨트)도 같은 경로로 접속할 수 있습니다.
# MAGIC
# MAGIC 1. 네트워크 확인 — 서버 FQDN이 사설 IP로 풀리는지
# MAGIC 2. 스키마 생성 + CSV 적재 (Microsoft sql-server-samples, 커밋 고정)
# MAGIC 3. 소스 설정 — 복제 사용자 · 권한 · REPLICA IDENTITY · publication (관리자 계정)
# MAGIC 4. 복제 슬롯 생성 (복제 사용자 계정, `pgoutput`)
# MAGIC 5. 문서의 확인 쿼리
# MAGIC
# MAGIC 접속 정보는 Terraform(`envs/lfc-pg-cdc`)이 만든 secret scope 2개에서 읽습니다.
# MAGIC `secret_scope` = 접속 정보·복제 사용자, `admin_secret_scope` = 서버 관리자(샘플 적재·원천 설정용).

# COMMAND ----------

# MAGIC %pip install "psycopg[binary]>=3.2,<4" --quiet

# COMMAND ----------

dbutils.library.restartPython()

# COMMAND ----------

dbutils.widgets.text("secret_scope", "")
dbutils.widgets.text("admin_secret_scope", "")
dbutils.widgets.text("publication", "databricks_publication")
dbutils.widgets.text("slot", "databricks_slot")
dbutils.widgets.dropdown("drop_existing", "false", ["false", "true"])

scope = dbutils.widgets.get("secret_scope")
admin_scope = dbutils.widgets.get("admin_secret_scope")
publication = dbutils.widgets.get("publication")
slot = dbutils.widgets.get("slot")
drop_existing = dbutils.widgets.get("drop_existing") == "true"


def secret(key: str) -> str:
    return dbutils.secrets.get(scope, key)


def admin_secret(key: str) -> str:
    return dbutils.secrets.get(admin_scope, key)


host = secret("pg-host")
database = secret("pg-database")
admin_user = admin_secret("pg-admin-user")
replication_user = secret("pg-replication-user")

# COMMAND ----------

# MAGIC %md ## 1. 네트워크 확인

# COMMAND ----------

import ipaddress
import socket

addr = socket.gethostbyname(host)
print(f"{host} -> {addr}")
assert ipaddress.ip_address(addr).is_private, "FQDN must resolve to the private IP (check the private DNS zone link to the workspace VNet)"

with socket.create_connection((addr, 5432), timeout=10):
    print("TCP 5432 reachable")

# COMMAND ----------

# MAGIC %md ## 2. 스키마 생성 + 적재

# COMMAND ----------

import psycopg

# aw_loader.py sits next to this notebook; the notebook directory is on sys.path.
import aw_loader as aw


def connect(user: str, password: str) -> psycopg.Connection:
    # Azure Database for PostgreSQL enforces TLS.
    return psycopg.connect(host=host, port=5432, dbname=database, user=user, password=password, sslmode="require")


admin = connect(admin_user, admin_secret("pg-admin-password"))
with admin.cursor() as cur:
    cur.execute("SELECT version(), current_setting('wal_level')")
    print(cur.fetchone())

aw.create_schema(admin, drop_existing=drop_existing)
counts = aw.load_all(admin)
print(f"total rows: {sum(counts.values()):,}")

# COMMAND ----------

# MAGIC %md ## 3. 소스 설정 (관리자 계정)

# COMMAND ----------

aw.setup_replication(
    admin,
    database=database,
    replication_user=replication_user,
    replication_password=secret("pg-replication-password"),
    publication=publication,
)
print("replication user, grants, replica identity, publication: done")

# COMMAND ----------

# MAGIC %md ## 4. 복제 슬롯 (복제 사용자 계정)
# MAGIC
# MAGIC 슬롯은 gateway가 소비하기 전까지 WAL을 붙잡습니다. 슬롯을 만든 뒤에는 gateway를 계속 실행하고,
# MAGIC 파이프라인을 지우면 슬롯도 직접 지워야 합니다(`SELECT pg_drop_replication_slot('databricks_slot')`).

# COMMAND ----------

replication = connect(replication_user, secret("pg-replication-password"))
created = aw.create_slot(replication, slot)
print(f"slot {slot}: {'created' if created else 'already exists'}")
replication.close()

# COMMAND ----------

# MAGIC %md ## 5. 확인

# COMMAND ----------

result = aw.verify(admin, replication_user, publication, slot)
for k, v in result.items():
    print(f"{k}: {v}")

assert result["wal_level"] == "logical"
assert result["replication_user_has_replication"] is True
assert result["publication_tables"] == len(aw.TABLES)
assert result["slot"] is not None and result["slot"][1] == "pgoutput"
admin.close()
