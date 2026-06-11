import os
import json
import argparse
import tempfile
import time
from pathlib import Path
from datetime import date, datetime, timedelta, timezone
from typing import Any, Dict, List, Optional

import pandas as pd
import requests
from google.api_core.exceptions import NotFound
from google.cloud import bigquery

PAYGURU_BASE_URL = os.getenv("PAYGURU_BASE_URL", "http://api.trend-tech.net").rstrip("/")
PAYGURU_MERCHANT_ID = os.getenv("PAYGURU_MERCHANT_ID", "").strip()
PAYGURU_SERVICE_IDS = [
    s.strip()
    for s in os.getenv("PAYGURU_SERVICE_IDS", "").split(",")
    if s.strip()
]

OUT_DIR = Path(os.getenv("OUT_DIR", "./payguru_outputs"))
DEBUG = os.getenv("DEBUG", "0") == "1"

API_TIMEOUT_SECONDS = int(os.getenv("API_TIMEOUT_SECONDS", "120"))
API_MAX_RETRIES = int(os.getenv("API_MAX_RETRIES", "3"))
API_RETRY_SLEEP_SECONDS = int(os.getenv("API_RETRY_SLEEP_SECONDS", "5"))

WRITE_CSV = os.getenv("WRITE_CSV", "0").strip() == "1"
BQ_ENABLED = os.getenv("BQ_ENABLED", "1").strip() == "1"
BQ_PROJECT_ID = os.getenv("BQ_PROJECT_ID", "microgain-9f959").strip()
BQ_DATASET = os.getenv("BQ_DATASET", "bc_t").strip()
BQ_TABLE = os.getenv("BQ_TABLE", "payguru_transactions_raw").strip()

if WRITE_CSV:
    OUT_DIR.mkdir(parents=True, exist_ok=True)

if not PAYGURU_MERCHANT_ID or not PAYGURU_SERVICE_IDS:
    raise RuntimeError(
        "Eksik env var: PAYGURU_MERCHANT_ID / PAYGURU_SERVICE_IDS"
    )


def resolve_dates(mode: str, start_arg: Optional[str], end_arg: Optional[str]):
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
            raise ValueError("custom için --start-date ve --end-date zorunlu")
        return date.fromisoformat(start_arg), date.fromisoformat(end_arg)

    raise ValueError("mode daily/manual/monthly/custom olmalı")


def search_transactions(
    start_date: date,
    end_date: date,
    service_id: str,
    page: int = 1,
    limit: int = 100
) -> Dict[str, Any]:
    url = f"{PAYGURU_BASE_URL}/MicroPayment/transactions/search"

    body = {
        "merchantId": int(PAYGURU_MERCHANT_ID),
        "serviceId": int(service_id),
        "search": [
            {
                "column": "modifiedDate",
                "term": start_date.isoformat(),
                "condition": ">="
            },
            {
                "column": "modifiedDate",
                "term": end_date.isoformat(),
                "condition": "<="
            }
        ],
        "sort": [
            {
                "column": "id",
                "asc": True
            }
        ],
        "limit": limit,
        "page": page
    }

    last_error = None

    for attempt in range(1, API_MAX_RETRIES + 1):
        try:
            resp = requests.post(url, json=body, timeout=API_TIMEOUT_SECONDS)

            if DEBUG:
                print("URL:", url)
                print("BODY:", json.dumps(body, ensure_ascii=False, indent=2))
                print("STATUS:", resp.status_code)
                print("RESP:", resp.text[:3000])

            try:
                payload = resp.json()
            except Exception:
                payload = {"raw_response": resp.text}

            if resp.status_code == 403:
                detail = payload.get("response", {}).get("resultDetail") if isinstance(payload, dict) else None
                desc = payload.get("response", {}).get("resultDescription") if isinstance(payload, dict) else None

                raise RuntimeError(
                    "[PAYGURU_AUTH_ERROR] Payguru API erişimi reddedildi.\n"
                    f"Status: {resp.status_code}\n"
                    f"Description: {desc}\n"
                    f"Detail: {detail}\n"
                    "Muhtemel sebep: IP whitelist eksik. Airflow/prod sunucu IP'si Payguru tarafında whitelist edilmeli."
                )

            if resp.status_code in (429, 500, 502, 503, 504):
                last_error = RuntimeError(f"Retryable Payguru API status={resp.status_code}")
                sleep_s = API_RETRY_SLEEP_SECONDS * attempt
                print(
                    f"[WARN] Payguru API retryable HTTP error: "
                    f"service_id={service_id} page={page} status={resp.status_code} "
                    f"attempt={attempt}/{API_MAX_RETRIES} sleep={sleep_s}s"
                )
                time.sleep(sleep_s)
                continue

            if resp.status_code >= 400:
                raise RuntimeError(
                    "[PAYGURU_API_ERROR]\n"
                    f"Status: {resp.status_code}\n"
                    f"Response: {json.dumps(payload, ensure_ascii=False)[:2000]}"
                )

            return payload

        except (requests.exceptions.Timeout, requests.exceptions.ConnectionError) as e:
            last_error = e
            sleep_s = API_RETRY_SLEEP_SECONDS * attempt
            print(
                f"[WARN] Payguru API timeout/connection error: "
                f"service_id={service_id} page={page} "
                f"attempt={attempt}/{API_MAX_RETRIES} sleep={sleep_s}s err={type(e).__name__}"
            )
            time.sleep(sleep_s)

    raise RuntimeError(
        f"Payguru API request failed after {API_MAX_RETRIES} attempts: "
        f"service_id={service_id} page={page} error={last_error}"
    )

def extract_transactions(payload: Dict[str, Any]) -> List[Dict[str, Any]]:
    for key in ["transactions", "transactionList", "data", "items", "results"]:
        value = payload.get(key)
        if isinstance(value, list):
            return value

    data = payload.get("data")
    if isinstance(data, dict):
        for key in ["transactions", "items", "results"]:
            value = data.get(key)
            if isinstance(value, list):
                return value

    return []


def normalize_transaction(t: Dict[str, Any]) -> Dict[str, Any]:
    return {
        "transaction_id": str(t.get("id") or t.get("transactionId") or ""),
        "service_id": str(t.get("service") or t.get("serviceId") or PAYGURU_SERVICE_IDS),
        "merchant_id": str(t.get("merchant") or t.get("merchantId") or PAYGURU_MERCHANT_ID),

        "transaction_date": t.get("transactionDate") or t.get("createDate") or t.get("createdDate"),
        "modified_date": t.get("modifiedDate") or t.get("updateDate") or t.get("updatedDate"),

        "amount": t.get("amount") or t.get("price"),
        "currency": t.get("currency") or "TRY",

        "status": t.get("status"),
        "status_text": t.get("statusText") or t.get("statusDescription"),
        "error": t.get("error"),
        "error_detail": t.get("errorDetail"),

        "operator": t.get("operator"),
        "msisdn": t.get("msisdn"),
        "reference_code": t.get("referenceCode"),
        "subscription_id": t.get("subscriptionId") or t.get("subscription"),

        "raw_json": json.dumps(t, ensure_ascii=False),
    }


def fetch_transactions(start_date, end_date):
    all_rows = []

    for service_id in PAYGURU_SERVICE_IDS:
        print(f"[INFO] service_id={service_id} çekiliyor...")

        page = 1
        limit = 100

        while True:
            payload = search_transactions(
                start_date=start_date,
                end_date=end_date,
                service_id=service_id,
                page=page,
                limit=limit,
            )

            txs = extract_transactions(payload)
            print(f"[INFO] service_id={service_id} page={page} tx_count={len(txs)}")

            for tx in txs:
                row = normalize_transaction(tx)
                row["service_id"] = service_id
                row["source_date"] = (
                    row.get("modified_date")
                    or row.get("transaction_date")
                    or start_date.isoformat()
                )
                all_rows.append(row)

            if len(txs) < limit:
                break

            page += 1

    return pd.DataFrame(all_rows)

#
# =============================
# BIGQUERY LOAD
# =============================
BQ_SCHEMA = [
    bigquery.SchemaField("transaction_id", "STRING"),
    bigquery.SchemaField("service_id", "STRING"),
    bigquery.SchemaField("merchant_id", "STRING"),
    bigquery.SchemaField("transaction_date", "TIMESTAMP"),
    bigquery.SchemaField("modified_date", "TIMESTAMP"),
    bigquery.SchemaField("amount", "FLOAT"),
    bigquery.SchemaField("currency", "STRING"),
    bigquery.SchemaField("status", "STRING"),
    bigquery.SchemaField("status_text", "STRING"),
    bigquery.SchemaField("error", "STRING"),
    bigquery.SchemaField("error_detail", "STRING"),
    bigquery.SchemaField("operator", "STRING"),
    bigquery.SchemaField("msisdn", "STRING"),
    bigquery.SchemaField("reference_code", "STRING"),
    bigquery.SchemaField("subscription_id", "STRING"),
    bigquery.SchemaField("source_date", "DATE"),
    bigquery.SchemaField("raw_json", "STRING"),
    bigquery.SchemaField("etl_loaded_at", "TIMESTAMP"),
]

FLOAT_COLUMNS = [
    "amount",
]

STRING_COLUMNS = [
    "transaction_id",
    "service_id",
    "merchant_id",
    "currency",
    "status",
    "status_text",
    "error",
    "error_detail",
    "operator",
    "msisdn",
    "reference_code",
    "subscription_id",
    "raw_json",
]

TIMESTAMP_COLUMNS = [
    "transaction_date",
    "modified_date",
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
            f"payguru_transactions_{args.mode}_{start_date.strftime('%Y%m%d')}_to_{end_date.strftime('%Y%m%d')}.csv"
        )
        df.to_csv(output_file, index=False, encoding="utf-8-sig")
        print(f"[OK] CSV saved: {output_file}")

    load_to_bigquery(df, start_date, end_date)
    print("[OK] Payguru export completed")


if __name__ == "__main__":
    main()