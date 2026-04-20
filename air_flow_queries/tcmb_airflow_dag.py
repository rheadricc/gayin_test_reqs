from airflow import DAG
from airflow.operators.python import PythonOperator
from airflow.providers.google.cloud.operators.bigquery import BigQueryInsertJobOperator
from datetime import datetime
import requests
import xml.etree.ElementTree as ET

from google.cloud import bigquery


PROJECT_ID = "your_project"
DATASET = "your_dataset"
TABLE = "tcmb_exchange_rates_daily"
STAGING_TABLE = "tcmb_exchange_rates_staging"


# -------------------------
# Helper functions
# -------------------------

def to_float(value):
    if value is None or value.strip() == "":
        return None
    try:
        return float(value)
    except:
        return None


def to_int(value):
    if value is None or value.strip() == "":
        return None
    try:
        return int(value)
    except:
        return None


def parse_date(date_str):
    return datetime.strptime(date_str, "%m/%d/%Y").date().isoformat()


# -------------------------
# Task 1: Fetch + Parse + Load to staging
# -------------------------

def fetch_and_load(**context):
    url = "https://www.tcmb.gov.tr/kurlar/today.xml"

    response = requests.get(url, timeout=30)
    response.raise_for_status()

    root = ET.fromstring(response.content)

    rate_date = parse_date(root.attrib.get("Date"))
    bulletin_no = root.attrib.get("Bulten_No")

    rows = []

    for currency in root.findall("Currency"):
        rows.append({
            "rate_date": rate_date,
            "bulletin_no": bulletin_no,
            "source_url": url,
            "cross_order": to_int(currency.attrib.get("CrossOrder")),
            "kod": currency.attrib.get("Kod"),
            "currency_code": currency.attrib.get("CurrencyCode"),
            "unit": to_int(currency.findtext("Unit")),
            "name_tr": currency.findtext("Isim"),
            "name_en": currency.findtext("CurrencyName"),
            "forex_buying": to_float(currency.findtext("ForexBuying")),
            "forex_selling": to_float(currency.findtext("ForexSelling")),
            "banknote_buying": to_float(currency.findtext("BanknoteBuying")),
            "banknote_selling": to_float(currency.findtext("BanknoteSelling")),
            "cross_rate_usd": to_float(currency.findtext("CrossRateUSD")),
            "cross_rate_other": to_float(currency.findtext("CrossRateOther")),
            "ingested_at": datetime.utcnow().isoformat()
        })

    client = bigquery.Client()

    table_id = f"{PROJECT_ID}.{DATASET}.{STAGING_TABLE}"

    errors = client.insert_rows_json(table_id, rows)

    if errors:
        raise Exception(f"BigQuery insert error: {errors}")


# -------------------------
# DAG
# -------------------------

default_args = {
    "owner": "data",
    "start_date": datetime(2024, 1, 1),
    "retries": 2
}

with DAG(
    dag_id="tcmb_exchange_rates_pipeline",
    default_args=default_args,
    schedule_interval="0 11 * * *",  # her gün 11:00
    catchup=False
) as dag:

    fetch_and_load_task = PythonOperator(
        task_id="fetch_and_load",
        python_callable=fetch_and_load
    )

    merge_to_main = BigQueryInsertJobOperator(
        task_id="merge_to_main",
        configuration={
            "query": {
                "query": f"""
                MERGE `{PROJECT_ID}.{DATASET}.{TABLE}` T
                USING `{PROJECT_ID}.{DATASET}.{STAGING_TABLE}` S
                ON T.rate_date = S.rate_date
                   AND T.currency_code = S.currency_code

                WHEN MATCHED THEN
                  UPDATE SET
                    bulletin_no = S.bulletin_no,
                    source_url = S.source_url,
                    cross_order = S.cross_order,
                    kod = S.kod,
                    unit = S.unit,
                    name_tr = S.name_tr,
                    name_en = S.name_en,
                    forex_buying = S.forex_buying,
                    forex_selling = S.forex_selling,
                    banknote_buying = S.banknote_buying,
                    banknote_selling = S.banknote_selling,
                    cross_rate_usd = S.cross_rate_usd,
                    cross_rate_other = S.cross_rate_other,
                    ingested_at = S.ingested_at

                WHEN NOT MATCHED THEN
                  INSERT ROW
                """,
                "useLegacySql": False
            }
        }
    )

    fetch_and_load_task >> merge_to_main