# Databricks notebook source
# MAGIC %md
# MAGIC # CDC 데모 — PostgreSQL 원천에 INSERT / UPDATE / DELETE 발생
# MAGIC
# MAGIC 01 노트북과 같은 클래식 컴퓨트에서 실행합니다. 데모용 행은 `comment = 'lfc-demo'`로 표시해 두고,
# MAGIC 실행 후 ingestion pipeline을 돌리면 Databricks 대상 테이블에서 같은 변경을 확인할 수 있습니다.
# MAGIC
# MAGIC | 단계 | 원천 변경 | 대상에서 확인 |
# MAGIC |---|---|---|
# MAGIC | INSERT | 새 주문 헤더 + 상세 행 | `comment = 'lfc-demo'` 주문이 생김 |
# MAGIC | UPDATE | 데모 주문 일부 상태·배송일 변경, 고객 이메일 수신 설정 변경 | 값이 바뀜 |
# MAGIC | DELETE | 데모 주문 1건의 상세 행 + 헤더 삭제 | 해당 주문이 사라짐 |

# COMMAND ----------

# MAGIC %pip install "psycopg[binary]>=3.2,<4" --quiet

# COMMAND ----------

dbutils.library.restartPython()

# COMMAND ----------

dbutils.widgets.text("secret_scope", "")
dbutils.widgets.text("admin_secret_scope", "")
dbutils.widgets.text("new_orders", "5")
dbutils.widgets.text("person_updates", "10")

scope = dbutils.widgets.get("secret_scope")
admin_scope = dbutils.widgets.get("admin_secret_scope")
new_orders = int(dbutils.widgets.get("new_orders"))
person_updates = int(dbutils.widgets.get("person_updates"))

from decimal import Decimal

import psycopg

conn = psycopg.connect(
    host=dbutils.secrets.get(scope, "pg-host"),
    port=5432,
    dbname=dbutils.secrets.get(scope, "pg-database"),
    user=dbutils.secrets.get(admin_scope, "pg-admin-user"),
    password=dbutils.secrets.get(admin_scope, "pg-admin-password"),
    sslmode="require",
)

# COMMAND ----------

# MAGIC %md ## INSERT — 새 주문

# COMMAND ----------

inserted = []
with conn.cursor() as cur:
    for _ in range(new_orders):
        # A random person customer with a known address, and 1-3 products sold under
        # special offer 1 ("No Discount"), like the original orders.
        cur.execute(
            """
            SELECT c.customerid, c.territoryid, h.billtoaddressid, h.shiptoaddressid, c.accountnumber
            FROM sales.customer c
            JOIN sales.salesorderheader h ON h.customerid = c.customerid
            ORDER BY random() LIMIT 1
            """
        )
        customerid, territoryid, billto, shipto, account = cur.fetchone()
        cur.execute(
            """
            SELECT p.productid, p.listprice
            FROM production.product p
            JOIN sales.specialofferproduct sop ON sop.productid = p.productid AND sop.specialofferid = 1
            WHERE p.listprice > 0
            ORDER BY random() LIMIT (1 + floor(random() * 3))::int
            """
        )
        lines = [(pid, price, 1 + int(i)) for i, (pid, price) in enumerate(cur.fetchall())]
        subtotal = sum(price * qty for _, price, qty in lines)  # numeric -> Decimal
        taxamt = round(subtotal * Decimal("0.08"), 4)
        freight = round(subtotal * Decimal("0.025"), 4)

        cur.execute(
            """
            INSERT INTO sales.salesorderheader
              (revisionnumber, orderdate, duedate, status, onlineorderflag, accountnumber,
               customerid, territoryid, billtoaddressid, shiptoaddressid, shipmethodid,
               subtotal, taxamt, freight, totaldue, comment)
            VALUES (0, now(), now() + interval '12 days', 1, true, %s, %s, %s, %s, %s, 1,
                    %s, %s, %s, %s, 'lfc-demo')
            RETURNING salesorderid
            """,
            (account, customerid, territoryid, billto, shipto, subtotal, taxamt, freight, subtotal + taxamt + freight),
        )
        orderid = cur.fetchone()[0]
        # salesordernumber is a computed column in SQL Server; keep it consistent.
        cur.execute(
            "UPDATE sales.salesorderheader SET salesordernumber = 'SO' || salesorderid WHERE salesorderid = %s",
            (orderid,),
        )
        for pid, price, qty in lines:
            cur.execute(
                """
                INSERT INTO sales.salesorderdetail
                  (salesorderid, orderqty, productid, specialofferid, unitprice, unitpricediscount, linetotal)
                VALUES (%s, %s, %s, 1, %s, 0, %s)
                """,
                (orderid, qty, pid, price, price * qty),
            )
        inserted.append(orderid)
conn.commit()
print("inserted orders:", inserted)

# COMMAND ----------

# MAGIC %md ## UPDATE — 주문 상태, 고객 속성

# COMMAND ----------

with conn.cursor() as cur:
    cur.execute(
        """
        UPDATE sales.salesorderheader
        SET status = 5, shipdate = now(), revisionnumber = revisionnumber + 1, modifieddate = now()
        WHERE comment = 'lfc-demo' AND status = 1 AND salesorderid <> ALL(%s)
        RETURNING salesorderid
        """,
        (inserted[:1],),
    )
    shipped = [r[0] for r in cur.fetchall()]
    cur.execute(
        """
        UPDATE person.person
        SET emailpromotion = (emailpromotion + 1) %% 3, modifieddate = now()  -- %% = modulo (psycopg escape)
        WHERE businessentityid IN (SELECT businessentityid FROM person.person ORDER BY random() LIMIT %s)
        RETURNING businessentityid, emailpromotion
        """,
        (person_updates,),
    )
    persons = cur.fetchall()
conn.commit()
print("shipped orders:", shipped)
print("person updates (businessentityid, emailpromotion):", persons)

# COMMAND ----------

# MAGIC %md ## DELETE — 데모 주문 1건 (가장 오래된 것)

# COMMAND ----------

with conn.cursor() as cur:
    cur.execute("SELECT min(salesorderid) FROM sales.salesorderheader WHERE comment = 'lfc-demo'")
    victim = cur.fetchone()[0]
    if victim is not None and victim not in inserted:
        cur.execute("DELETE FROM sales.salesorderdetail WHERE salesorderid = %s", (victim,))
        cur.execute("DELETE FROM sales.salesorderheader WHERE salesorderid = %s", (victim,))
conn.commit()
print("deleted order:", victim if victim not in inserted else None)

# COMMAND ----------

# MAGIC %md
# MAGIC ## 대상 확인 (ingestion pipeline 실행 후)
# MAGIC
# MAGIC ```sql
# MAGIC SELECT salesorderid, status, shipdate, totaldue, comment
# MAGIC FROM <catalog>.adventureworks.salesorderheader
# MAGIC WHERE comment = 'lfc-demo'
# MAGIC ORDER BY salesorderid;
# MAGIC ```
# MAGIC 처음 실행할 때 지운 주문은 그 전 실행에서 만든 주문입니다. 한 번만 실행했다면 DELETE는 건너뜁니다.

# COMMAND ----------

with conn.cursor() as cur:
    cur.execute(
        "SELECT salesorderid, status, shipdate, totaldue FROM sales.salesorderheader WHERE comment = 'lfc-demo' ORDER BY 1"
    )
    for row in cur.fetchall():
        print(row)
    cur.execute("SELECT slot_name, active, confirmed_flush_lsn FROM pg_replication_slots")
    print("slots:", cur.fetchall())
conn.close()
