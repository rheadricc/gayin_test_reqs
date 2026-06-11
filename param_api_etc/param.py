import os
import time
import json
import argparse
import requests
import pandas as pd
from pathlib import Path
import tempfile
from datetime import date, datetime, timedelta, timezone
from lxml import etree
from dotenv import load_dotenv
from google.api_core.exceptions import NotFound
from google.cloud import bigquery


# =========================
# ENV
# =========================
load_dotenv(dotenv_path=Path(__file__).resolve().parent / ".env")

SOAP_URL = os.getenv(
    "TURKPOS_SOAP_URL",
    "https://posws.param.com.tr/turkpos.ws/service_turkpos_prod.asmx",
).strip()

CLIENT_CODE = os.getenv("TURKPOS_CLIENT_CODE", "").strip()
CLIENT_USERNAME = os.getenv("TURKPOS_CLIENT_USERNAME", "").strip()
CLIENT_PASSWORD = os.getenv("TURKPOS_CLIENT_PASSWORD", "").strip()
GUID = os.getenv("TURKPOS_GUID", "").strip()

OUT_DIR = Path(os.getenv("OUT_DIR", "./param_outputs"))
DEBUG = os.getenv("DEBUG", "0") == "1"
SLEEP_SEC = float(os.getenv("SLEEP_SEC", "0.2"))

SOAP_TIMEOUT_SECONDS = int(os.getenv("SOAP_TIMEOUT_SECONDS", "120"))
SOAP_MAX_RETRIES = int(os.getenv("SOAP_MAX_RETRIES", "3"))
SOAP_RETRY_SLEEP_SECONDS = int(os.getenv("SOAP_RETRY_SLEEP_SECONDS", "5"))

WRITE_CSV = os.getenv("WRITE_CSV", "0").strip() == "1"
BQ_ENABLED = os.getenv("BQ_ENABLED", "1").strip() == "1"
BQ_PROJECT_ID = os.getenv("BQ_PROJECT_ID", "microgain-9f959").strip()
BQ_DATASET = os.getenv("BQ_DATASET", "bc_t").strip()
BQ_TABLE = os.getenv("BQ_TABLE", "param_transactions_raw").strip()

if WRITE_CSV:
    OUT_DIR.mkdir(parents=True, exist_ok=True)

if not all([SOAP_URL, CLIENT_CODE, CLIENT_USERNAME, CLIENT_PASSWORD, GUID]):
    raise RuntimeError("Eksik env var: TURKPOS_* değerlerini kontrol et.")


# =========================
# DATE
# =========================
def resolve_dates(mode: str, start_arg=None, end_arg=None):
    today = datetime.now(timezone.utc).date()
    yesterday = today - timedelta(days=1)

    if mode == "daily":
        return yesterday, yesterday

    if mode == "manual":
        return today.replace(day=1), yesterday

    if mode == "monthly":
        first_this_month = today.replace(day=1)
        last_prev_month = first_this_month - timedelta(days=1)
        first_prev_month = last_prev_month.replace(day=1)
        return first_prev_month, last_prev_month

    if mode == "custom":
        if not start_arg or not end_arg:
            raise ValueError("custom mode için --start-date ve --end-date zorunlu")
        return date.fromisoformat(start_arg), date.fromisoformat(end_arg)

    raise ValueError("mode daily/manual/monthly/custom olmalı")


def daterange(start: date, end: date):
    cur = start
    while cur <= end:
        yield cur
        cur += timedelta(days=1)


# =========================
# SOAP
# =========================
def build_mutabakat_xml(day: date) -> str:
    tarih_str = day.strftime("%d.%m.%Y 00:00:00")

    return f"""<?xml version="1.0" encoding="utf-8"?>
<soap:Envelope xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
               xmlns:xsd="http://www.w3.org/2001/XMLSchema"
               xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">
  <soap:Body>
    <TP_Mutabakat_Detay xmlns="https://turkpos.com.tr/">
      <G>
        <CLIENT_CODE>{CLIENT_CODE}</CLIENT_CODE>
        <CLIENT_USERNAME>{CLIENT_USERNAME}</CLIENT_USERNAME>
        <CLIENT_PASSWORD>{CLIENT_PASSWORD}</CLIENT_PASSWORD>
      </G>
      <GUID>{GUID}</GUID>
      <Tarih>{tarih_str}</Tarih>
    </TP_Mutabakat_Detay>
  </soap:Body>
</soap:Envelope>"""


def post_soap(xml_body: str, request_date: date) -> bytes:
    headers = {
        "Content-Type": "text/xml; charset=utf-8",
        "SOAPAction": '"https://turkpos.com.tr/TP_Mutabakat_Detay"',
    }

    last_error = None

    for attempt in range(1, SOAP_MAX_RETRIES + 1):
        try:
            resp = requests.post(
                SOAP_URL,
                data=xml_body.encode("utf-8"),
                headers=headers,
                timeout=SOAP_TIMEOUT_SECONDS,
            )

            if DEBUG:
                print("STATUS:", resp.status_code)
                print(resp.text[:1000])

            resp.raise_for_status()
            return resp.content

        except (requests.exceptions.Timeout, requests.exceptions.ConnectionError) as e:
            last_error = e
            sleep_s = SOAP_RETRY_SLEEP_SECONDS * attempt
            print(
                f"[WARN] Param SOAP timeout/connection error: "
                f"date={request_date} attempt={attempt}/{SOAP_MAX_RETRIES} "
                f"sleep={sleep_s}s err={type(e).__name__}"
            )
            time.sleep(sleep_s)

        except requests.exceptions.HTTPError as e:
            status_code = e.response.status_code if e.response is not None else None
            last_error = e

            if status_code in (429, 500, 502, 503, 504):
                sleep_s = SOAP_RETRY_SLEEP_SECONDS * attempt
                print(
                    f"[WARN] Param SOAP retryable HTTP error: "
                    f"date={request_date} status={status_code} "
                    f"attempt={attempt}/{SOAP_MAX_RETRIES} sleep={sleep_s}s"
                )
                time.sleep(sleep_s)
                continue

            raise

    raise RuntimeError(
        f"Param SOAP request failed after {SOAP_MAX_RETRIES} attempts: "
        f"date={request_date} error={last_error}"
    )


def parse_mutabakat_rows(xml_bytes: bytes) -> list[dict]:
    root = etree.fromstring(xml_bytes)
    nodes = root.xpath("//*[local-name()='DT_Mutabakat_Detay']")

    rows = []
    for node in nodes:
        row = {}
        for child in node:
            key = etree.QName(child).localname
            row[key] = (child.text or "").strip()
        rows.append(row)

    return rows


# =========================
# NORMALIZE
# =========================
def parse_tr_amount(value):
    if value is None or value == "":
        return None

    return float(
        str(value)
        .replace(".", "")
        .replace(",", ".")
        .strip()
    )


def parse_tr_datetime(value):
    if not value:
        return None

    parsed = pd.to_datetime(value, dayfirst=True, errors="coerce")
    return parsed.isoformat() if pd.notna(parsed) else None


def normalize_transaction(row: dict, source_date: str) -> dict:
    return {
        "transaction_id": row.get("PROVIZYON_NO") or "",
        "order_id": row.get("SIPARIS_NO") or "",

        "transaction_date": parse_tr_datetime(row.get("ISLEM_TARIHI")),
        "settlement_date": row.get("VALOR_TARIHI") or "",
        "batch_close_date": parse_tr_datetime(row.get("GUNSONU_TARIHI")),

        "transaction_type": row.get("TRANSACTION_TIPI") or "",
        "currency": "TRY",

        "gross_amount": parse_tr_amount(row.get("PROVIZYON_TUTARI")),
        "commission_amount": parse_tr_amount(row.get("KOMISYON_TUTARI")),
        "commission_rate": parse_tr_amount(row.get("KOMISYON_ORANI")),
        "net_amount": parse_tr_amount(row.get("NET_TUTAR")),

        "installment_index": row.get("TAKSIT_SIRASI") or "",
        "installment_count": row.get("TAKSIT_SAYISI") or "",

        "card_masked": row.get("KART_NO") or "",
        "card_type": row.get("ANA_KART_TIPI") or "",
        "bank": row.get("ALT_KART_TIPI") or "",

        "source": "param",
        "source_date": source_date,
        "raw_json": json.dumps(row, ensure_ascii=False),
    }


# =========================
# FETCH
# =========================
def fetch_transactions(start_date: date, end_date: date) -> pd.DataFrame:
    rows = []

    print(f"[INFO] Param transactions çekiliyor: {start_date}..{end_date}")

    for day in daterange(start_date, end_date):
        xml = build_mutabakat_xml(day)
        resp = post_soap(xml, request_date=day)
        raw_rows = parse_mutabakat_rows(resp)

        print(f"[INFO] {day} rows={len(raw_rows)}")

        for raw in raw_rows:
            rows.append(normalize_transaction(raw, source_date=str(day)))

        time.sleep(SLEEP_SEC)

    return pd.DataFrame(rows)


# =============================
# BIGQUERY LOAD
# =============================
BQ_SCHEMA = [
    bigquery.SchemaField("transaction_id", "STRING"),
    bigquery.SchemaField("order_id", "STRING"),
    bigquery.SchemaField("transaction_date", "TIMESTAMP"),
    bigquery.SchemaField("settlement_date", "STRING"),
    bigquery.SchemaField("batch_close_date", "TIMESTAMP"),
    bigquery.SchemaField("transaction_type", "STRING"),
    bigquery.SchemaField("currency", "STRING"),
    bigquery.SchemaField("gross_amount", "FLOAT"),
    bigquery.SchemaField("commission_amount", "FLOAT"),
    bigquery.SchemaField("commission_rate", "FLOAT"),
    bigquery.SchemaField("net_amount", "FLOAT"),
    bigquery.SchemaField("installment_index", "STRING"),
    bigquery.SchemaField("installment_count", "STRING"),
    bigquery.SchemaField("card_masked", "STRING"),
    bigquery.SchemaField("card_type", "STRING"),
    bigquery.SchemaField("bank", "STRING"),
    bigquery.SchemaField("source", "STRING"),
    bigquery.SchemaField("source_date", "DATE"),
    bigquery.SchemaField("raw_json", "STRING"),
    bigquery.SchemaField("etl_loaded_at", "TIMESTAMP"),
]

FLOAT_COLUMNS = [
    "gross_amount",
    "commission_amount",
    "commission_rate",
    "net_amount",
]

STRING_COLUMNS = [
    "transaction_id",
    "order_id",
    "settlement_date",
    "transaction_type",
    "currency",
    "installment_index",
    "installment_count",
    "card_masked",
    "card_type",
    "bank",
    "source",
    "raw_json",
]

TIMESTAMP_COLUMNS = [
    "transaction_date",
    "batch_close_date",
    "etl_loaded_at",
]


def prepare_bigquery_dataframe(df: pd.DataFrame) -> pd.DataFrame:
    df = df.copy()

    expected_columns = [field.name for field in BQ_SCHEMA]
    for col in expected_columns:
        if col not in df.columns:
            df[col] = None

    df["source_date"] = pd.to_datetime(df["source_date"], errors="coerce").dt.strftime("%Y-%m-%d")
    df["etl_loaded_at"] = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S")

    for col in FLOAT_COLUMNS:
        df[col] = pd.to_numeric(df[col], errors="coerce")

    for col in TIMESTAMP_COLUMNS:
        df[col] = pd.to_datetime(df[col], errors="coerce", utc=True).dt.strftime("%Y-%m-%d %H:%M:%S")
        df[col] = df[col].replace("NaT", None)

    for col in STRING_COLUMNS:
        df[col] = df[col].where(pd.notna(df[col]), None)
        df[col] = df[col].apply(lambda x: None if x is None else str(x))

    df = df[expected_columns]
    df = df.where(pd.notna(df), None)
    return df


def sanitize_rows_for_bigquery(rows: list[dict]) -> list[dict]:
    sanitized_rows = []

    for row in rows:
        clean_row = {}

        for key, value in row.items():
            if pd.isna(value):
                clean_row[key] = None
            elif isinstance(value, (date, datetime)):
                clean_row[key] = value.isoformat()
            else:
                clean_row[key] = value

        sanitized_rows.append(clean_row)

    return sanitized_rows


def ensure_bigquery_table(client: bigquery.Client, table_id: str) -> None:
    try:
        client.get_table(table_id)
        return
    except NotFound:
        table = bigquery.Table(table_id, schema=BQ_SCHEMA)
        table.time_partitioning = bigquery.TimePartitioning(
            type_=bigquery.TimePartitioningType.DAY,
            field="source_date",
        )
        client.create_table(table)
        print(f"[BQ] Table created: {table_id}")


def delete_existing_bigquery_rows(client: bigquery.Client, table_id: str, start_date: date, end_date: date) -> None:
    sql = f"""
    DELETE FROM `{table_id}`
    WHERE source_date BETWEEN @start_date AND @end_date
    """
    job_config = bigquery.QueryJobConfig(
        query_parameters=[
            bigquery.ScalarQueryParameter("start_date", "DATE", start_date.isoformat()),
            bigquery.ScalarQueryParameter("end_date", "DATE", end_date.isoformat()),
        ]
    )
    client.query(sql, job_config=job_config).result()
    print(f"[BQ] Existing rows deleted: {table_id} / {start_date}..{end_date}")


def load_to_bigquery(df: pd.DataFrame, start_date: date, end_date: date) -> None:
    if not BQ_ENABLED:
        print("[BQ] BQ_ENABLED=0, BigQuery load atlandı.")
        return

    table_id = f"{BQ_PROJECT_ID}.{BQ_DATASET}.{BQ_TABLE}"
    client = bigquery.Client(project=BQ_PROJECT_ID)
    ensure_bigquery_table(client, table_id)
    delete_existing_bigquery_rows(client, table_id, start_date, end_date)

    df_bq = prepare_bigquery_dataframe(df)
    rows = sanitize_rows_for_bigquery(df_bq.to_dict(orient="records"))

    if not rows:
        print(f"[BQ] Loaded rows: 0 → {table_id}")
        return

    with tempfile.NamedTemporaryFile(mode="w+b", suffix=".jsonl") as tmp_file:
        for row in rows:
            line = json.dumps(row, ensure_ascii=False, default=str) + "\n"
            tmp_file.write(line.encode("utf-8"))

        tmp_file.flush()
        tmp_file.seek(0)

        job_config = bigquery.LoadJobConfig(
            schema=BQ_SCHEMA,
            source_format=bigquery.SourceFormat.NEWLINE_DELIMITED_JSON,
            write_disposition=bigquery.WriteDisposition.WRITE_APPEND,
        )

        load_job = client.load_table_from_file(
            tmp_file,
            table_id,
            job_config=job_config,
        )
        load_job.result()

    print(f"[BQ] Loaded rows: {len(rows)} → {table_id}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=["daily", "manual", "monthly", "custom"])
    parser.add_argument("--start-date")
    parser.add_argument("--end-date")
    args = parser.parse_args()

    start_date, end_date = resolve_dates(args.mode, args.start_date, args.end_date)
    df = fetch_transactions(start_date, end_date)

    print(f"[OK] Rows fetched: {len(df)}")

    if WRITE_CSV:
        output_file = OUT_DIR / (
            f"param_transactions_{args.mode}_{start_date.strftime('%Y%m%d')}_to_{end_date.strftime('%Y%m%d')}.csv"
        )
        df.to_csv(output_file, index=False, encoding="utf-8-sig")
        print(f"[OK] CSV saved: {output_file}")

    load_to_bigquery(df, start_date, end_date)
    print("[OK] Param export completed")


if __name__ == "__main__":
    main()