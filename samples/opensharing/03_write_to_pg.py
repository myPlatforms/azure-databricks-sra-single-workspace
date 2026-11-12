# Databricks notebook source
# MAGIC %md
# MAGIC # 수신 워크스페이스 → 제공자 리전 PostgreSQL 결과 반영
# MAGIC
# MAGIC 수신 워크스페이스에서 읽은 데이터(예: OpenSharing으로 받은 `v_orders_europe`)를
# MAGIC 일 단위로 집계해 제공자 리전의 사설 PostgreSQL에 씁니다. 같은 노트북을 두 경로로 실행합니다.
# MAGIC
# MAGIC | writer | 컴퓨트 | 네트워크 경로 |
# MAGIC |---|---|---|
# MAGIC | `psycopg` | 서버리스 | Private Network Gateway → 수신 워크스페이스 VNet → 글로벌 VNet 피어링 → PostgreSQL |
# MAGIC | `jdbc` | 클래식 | 수신 워크스페이스 VNet(host/container) → 글로벌 VNet 피어링 → PostgreSQL |
# MAGIC
# MAGIC Lakehouse Federation(UC 연결)은 읽기 전용이므로 쓰기는 드라이버로 직접 합니다.
# MAGIC 쓰기 계정은 대상 스키마에만 `USAGE, CREATE` 권한을 가진 역할입니다. 스키마는 DB 담당 팀이 미리 만들고
# MAGIC `create_schema = false`로 실행합니다(`CREATE SCHEMA`는 데이터베이스 `CREATE` 권한이 필요).

# COMMAND ----------

dbutils.widgets.text("secret_scope", "")
dbutils.widgets.text("source_table", "")
dbutils.widgets.text("target_table", "reporting.orders_daily")
dbutils.widgets.dropdown("writer", "psycopg", ["psycopg", "jdbc"])
dbutils.widgets.dropdown("create_schema", "false", ["false", "true"])
dbutils.widgets.text("loaded_by", "recipient")

scope = dbutils.widgets.get("secret_scope")
source_table = dbutils.widgets.get("source_table")
target_table = dbutils.widgets.get("target_table")
writer = dbutils.widgets.get("writer")
create_schema = dbutils.widgets.get("create_schema") == "true"
loaded_by = dbutils.widgets.get("loaded_by")
target_schema = target_table.split(".")[0]

host = dbutils.secrets.get(scope, "pg-host")
database = dbutils.secrets.get(scope, "pg-database")
user = dbutils.secrets.get(scope, "pg-user")
password = dbutils.secrets.get(scope, "pg-password")

# COMMAND ----------

# MAGIC %md ## 1. 원본 읽기 + 집계

# COMMAND ----------

from pyspark.sql import functions as F

daily = (
    spark.table(source_table)
    .groupBy(F.to_date("orderdate").alias("order_date"), "territory")
    .agg(F.count("*").alias("orders"), F.sum("totaldue").cast("decimal(19,4)").alias("total_due"))
    .withColumn("loaded_by", F.lit(f"{loaded_by}/{writer}"))
    .withColumn("loaded_at", F.current_timestamp())
    .orderBy("order_date", "territory")
)
rows = daily.count()
print(f"{source_table} -> {rows} daily rows")

# COMMAND ----------

# MAGIC %md ## 2. PostgreSQL에 쓰기

# COMMAND ----------

if writer == "jdbc":
    # Classic: the PostgreSQL JDBC driver ships with Databricks Runtime.
    url = f"jdbc:postgresql://{host}:5432/{database}?sslmode=require"
    props = {"user": user, "password": password, "driver": "org.postgresql.Driver"}
    if create_schema:
        # Spark does not create the schema; do it with a one-off JDBC statement.
        jvm = spark.sparkContext._jvm
        conn = jvm.java.sql.DriverManager.getConnection(url, user, password)
        try:
            conn.createStatement().execute(f"CREATE SCHEMA IF NOT EXISTS {target_schema}")
        finally:
            conn.close()
    (
        daily.write.format("jdbc")
        .option("url", url)
        .option("dbtable", target_table)
        .option("truncate", "true")  # keep the table, replace its rows
        .options(**props)
        .mode("overwrite")
        .save()
    )
else:
    # Serverless: psycopg comes from the job environment (pypi.org is on the
    # serverless network policy allow list).
    import psycopg

    data = [tuple(r) for r in daily.collect()]
    with psycopg.connect(host=host, port=5432, dbname=database, user=user, password=password, sslmode="require") as conn:
        with conn.cursor() as cur:
            if create_schema:
                cur.execute(f"CREATE SCHEMA IF NOT EXISTS {target_schema}")
            cur.execute(
                f"""CREATE TABLE IF NOT EXISTS {target_table} (
                    order_date date, territory varchar(50), orders bigint,
                    total_due numeric(19,4), loaded_by text, loaded_at timestamptz,
                    PRIMARY KEY (order_date, territory))"""
            )
            cur.execute(f"TRUNCATE {target_table}")
            cur.executemany(
                f"INSERT INTO {target_table} (order_date, territory, orders, total_due, loaded_by, loaded_at) "
                "VALUES (%s, %s, %s, %s, %s, %s)",
                data,
            )
        conn.commit()

# COMMAND ----------

# MAGIC %md ## 3. 확인 — 같은 경로로 다시 읽기

# COMMAND ----------

check_sql = f"SELECT count(*) AS n, sum(orders) AS orders, inet_server_addr()::text AS server_ip FROM {target_table}"
if writer == "jdbc":
    back = (
        spark.read.format("jdbc")
        .option("url", f"jdbc:postgresql://{host}:5432/{database}?sslmode=require")
        .option("query", check_sql)
        .option("user", user)
        .option("password", password)
        .option("driver", "org.postgresql.Driver")
        .load()
        .collect()[0]
    )
    n, orders, server_ip = back["n"], back["orders"], back["server_ip"]
else:
    with psycopg.connect(host=host, port=5432, dbname=database, user=user, password=password, sslmode="require") as conn:
        n, orders, server_ip = conn.execute(check_sql).fetchone()

print(f"{target_table}: {n} rows, {orders} orders, server {server_ip}")
assert n == rows, f"expected {rows} rows, found {n}"
dbutils.notebook.exit(f"{writer}: {n} rows -> {target_table} @ {server_ip}")
