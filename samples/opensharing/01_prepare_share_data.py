# Databricks notebook source
# MAGIC %md
# MAGIC # 제공자: 공유할 데이터 준비 (Federation 카탈로그 → 관리형 Delta)
# MAGIC
# MAGIC 사설 PostgreSQL을 Lakehouse Federation 카탈로그(`source_catalog`)로 읽어, 제공자 UC 스토리지의
# MAGIC **관리형 Delta 테이블**로 복사하고 필터 뷰를 만듭니다. 관리형 Delta 테이블이어야 share에 `WITH HISTORY`로 넣을 수 있습니다.
# MAGIC
# MAGIC - 실행: 제공자 워크스페이스의 **서버리스**(노트북 또는 SQL warehouse). 경로 = PNG → 워크스페이스 VNet → 피어링 → PostgreSQL
# MAGIC - 선행: 조회 전용 역할로 만든 UC 연결과 foreign catalog (가이드 2.3 "공유 데이터 준비")
# MAGIC - 결과 스키마 `<share_catalog>.<share_schema>`를 `envs/opensharing`의 `source_schema`로 지정합니다.
# MAGIC
# MAGIC 테이블과 컬럼은 AdventureWorks 샘플 기준입니다. 다른 원천이면 `STATEMENTS`를 바꿉니다.

# COMMAND ----------

dbutils.widgets.text("source_catalog", "")  # foreign catalog on the PostgreSQL database
dbutils.widgets.text("share_catalog", "")  # managed catalog on the provider metastore
dbutils.widgets.text("share_schema", "aw_share")

source = dbutils.widgets.get("source_catalog").strip()
catalog = dbutils.widgets.get("share_catalog").strip()
schema = dbutils.widgets.get("share_schema").strip()
assert source and catalog and schema, "set source_catalog, share_catalog and share_schema"


def q(*parts: str) -> str:
    """Backtick-quoted multipart name."""
    return ".".join(f"`{p.replace('`', '``')}`" for p in parts)


target = q(catalog, schema)

# COMMAND ----------

STATEMENTS = [
    f"CREATE SCHEMA IF NOT EXISTS {target} COMMENT 'Objects shared via OpenSharing (SecureConnect)'",
    f"CREATE OR REPLACE TABLE {target}.salesterritory AS SELECT * FROM {q(source, 'sales', 'salesterritory')}",
    f"""CREATE OR REPLACE TABLE {target}.customer AS
        SELECT customerid, personid, storeid, territoryid, accountnumber, modifieddate
        FROM {q(source, 'sales', 'customer')}""",
    f"""CREATE OR REPLACE TABLE {target}.product AS
        SELECT productid, name, productnumber, color, standardcost, listprice, size, weight,
               productsubcategoryid, sellstartdate, sellenddate, modifieddate
        FROM {q(source, 'production', 'product')}""",
    f"""CREATE OR REPLACE TABLE {target}.salesorderheader AS
        SELECT salesorderid, revisionnumber, orderdate, duedate, shipdate, status, onlineorderflag,
               salesordernumber, customerid, salespersonid, territoryid, shipmethodid,
               subtotal, taxamt, freight, totaldue, modifieddate
        FROM {q(source, 'sales', 'salesorderheader')}""",
    f"""CREATE OR REPLACE TABLE {target}.salesorderdetail AS
        SELECT salesorderid, salesorderdetailid, orderqty, productid, specialofferid,
               unitprice, unitpricediscount, linetotal, modifieddate
        FROM {q(source, 'sales', 'salesorderdetail')}""",
    # Shared view: only European orders leave the provider (filtered on the provider side).
    f"""CREATE OR REPLACE VIEW {target}.v_orders_europe
        COMMENT 'Orders in European sales territories only'
        AS
        SELECT h.salesorderid, h.orderdate, h.status, h.customerid, t.name AS territory,
               t.countryregioncode, h.subtotal, h.taxamt, h.freight, h.totaldue
        FROM {target}.salesorderheader h
        JOIN {target}.salesterritory t ON t.territoryid = h.territoryid
        WHERE t.territorygroup = 'Europe'""",
]

for sql in STATEMENTS:
    print(sql.split(" AS")[0].strip())
    spark.sql(sql)

# COMMAND ----------

display(
    spark.sql(f"""
    SELECT 'salesorderheader' AS object, count(*) AS rows FROM {target}.salesorderheader
    UNION ALL SELECT 'v_orders_europe', count(*) FROM {target}.v_orders_europe
    """)
)
