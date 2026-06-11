## Ödemelerin dökümünü almak için .env içerisindeki NKOLAY_SX değerini NKOLAY_LIST_SX olarak değiştirerek aşağıdaki kodu çalıştırabilirsiniz.

import os
import json
import base64
import hashlib
import argparse
import tempfile
import time
from pathlib import Path
from datetime import date, datetime, timedelta, timezone
from typing import Optional, Any, Dict, List

import pandas as pd
import requests
from google.api_core.exceptions import NotFound
from google.cloud import bigquery



NKOLAY_BASE_URL = os.getenv(
    "NKOLAY_BASE_URL",
    "https://paynkolaytest.nkolayislem.com.tr"
).rstrip("/")

NKOLAY_LIST_SX = os.getenv("NKOLAY_LIST_SX", "").strip()
NKOLAY_MERCHANT_SECRET_KEY = os.getenv("NKOLAY_MERCHANT_SECRET_KEY", "").strip()

OUT_DIR = Path(os.getenv("OUT_DIR", "./nkolay_outputs"))
DEBUG = os.getenv("DEBUG", "0") == "1"

API_TIMEOUT_SECONDS = int(os.getenv("API_TIMEOUT_SECONDS", "120"))
API_MAX_RETRIES = int(os.getenv("API_MAX_RETRIES", "3"))
API_RETRY_SLEEP_SECONDS = int(os.getenv("API_RETRY_SLEEP_SECONDS", "5"))

WRITE_CSV = os.getenv("WRITE_CSV", "0").strip() == "1"
BQ_ENABLED = os.getenv("BQ_ENABLED", "1").strip() == "1"
BQ_PROJECT_ID = os.getenv("BQ_PROJECT_ID", "microgain-9f959").strip()
BQ_DATASET = os.getenv("BQ_DATASET", "bc_t").strip()
BQ_TABLE = os.getenv("BQ_TABLE", "nkolay_transactions_raw").strip()

if WRITE_CSV:
    OUT_DIR.mkdir(parents=True, exist_ok=True)

if not NKOLAY_LIST_SX or not NKOLAY_MERCHANT_SECRET_KEY:
    raise RuntimeError(
        "Eksik env var: NKOLAY_LIST_SX / NKOLAY_MERCHANT_SECRET_KEY"
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


def format_nkolay_date(d: date) -> str:
    return d.strftime("%d.%m.%Y")


def build_hash(sx: str, start_date: str, end_date: str, client_ref_code: str) -> str:
    raw = f"{sx}|{start_date}|{end_date}|{client_ref_code}|{NKOLAY_MERCHANT_SECRET_KEY}"
    digest = hashlib.sha512(raw.encode("utf-8")).digest()
    return base64.b64encode(digest).decode("utf-8")


def payment_list(start_date: date, end_date: date, client_ref_code: str = "") -> Dict[str, Any]:
    url = f"{NKOLAY_BASE_URL}/Vpos/Payment/PaymentList"

    start_str = format_nkolay_date(start_date)
    end_str = format_nkolay_date(end_date)

    hash_data = build_hash(
        sx=NKOLAY_LIST_SX,
        start_date=start_str,
        end_date=end_str,
        client_ref_code=client_ref_code,
    )

    data = {
        "sx": NKOLAY_LIST_SX,
        "startDate": start_str,
        "endDate": end_str,
        "clientRefCode": client_ref_code,
        "hashDatav2": hash_data,
    }

    last_error = None

    for attempt in range(1, API_MAX_RETRIES + 1):
        try:
            resp = requests.post(url, data=data, timeout=API_TIMEOUT_SECONDS)

            if DEBUG:
                safe_data = dict(data)
                safe_data["sx"] = "***"
                safe_data["hashDatav2"] = "***"
                print("URL:", url)
                print("FORM:", json.dumps(safe_data, ensure_ascii=False, indent=2))
                print("STATUS:", resp.status_code)
                print("RESP:", resp.text[:3000])

            try:
                payload = resp.json()
            except Exception:
                payload = {"raw_response": resp.text}

            if resp.status_code in (429, 500, 502, 503, 504):
                last_error = RuntimeError(f"Retryable N Kolay API status={resp.status_code}")
                sleep_s = API_RETRY_SLEEP_SECONDS * attempt
                print(
                    f"[WARN] N Kolay API retryable HTTP error: "
                    f"date={start_date}..{end_date} status={resp.status_code} "
                    f"attempt={attempt}/{API_MAX_RETRIES} sleep={sleep_s}s"
                )
                time.sleep(sleep_s)
                continue

            if resp.status_code >= 400:
                raise RuntimeError(
                    "[NKOLAY_API_ERROR]\n"
                    f"Status: {resp.status_code}\n"
                    f"Response: {json.dumps(payload, ensure_ascii=False)[:2000]}"
                )

            return payload

        except (requests.exceptions.Timeout, requests.exceptions.ConnectionError) as e:
            last_error = e
            sleep_s = API_RETRY_SLEEP_SECONDS * attempt
            print(
                f"[WARN] N Kolay API timeout/connection error: "
                f"date={start_date}..{end_date} "
                f"attempt={attempt}/{API_MAX_RETRIES} sleep={sleep_s}s err={type(e).__name__}"
            )
            time.sleep(sleep_s)

    raise RuntimeError(
        f"N Kolay API request failed after {API_MAX_RETRIES} attempts: "
        f"date={start_date}..{end_date} error={last_error}"
    )


def extract_transactions(payload: Dict[str, Any]) -> List[Dict[str, Any]]:
    # Bazı response'larda result string olarak geliyor.
    result = payload.get("result")

    if isinstance(result, str):
        try:
            result = json.loads(result)
        except Exception:
            return []

    if isinstance(result, dict):
        txs = result.get("LIST")
        if isinstance(txs, list):
            return txs

        response_data = result.get("RESPONSE_DATA")
        if isinstance(response_data, list):
            return response_data

    # Olası diğer formatlar için fallback
    for key in [
        "LIST",
        "list",
        "data",
        "Data",
        "transactions",
        "Transactions",
        "paymentList",
        "PaymentList",
    ]:
        value = payload.get(key)
        if isinstance(value, list):
            return value

    return []


def parse_amount(value):
    if value in [None, ""]:
        return None
    try:
        return float(str(value).replace(",", "."))
    except Exception:
        return None


def parse_nkolay_datetime(value):
    if not value:
        return None

    parsed = pd.to_datetime(value, dayfirst=True, errors="coerce")
    return parsed.isoformat() if pd.notna(parsed) else None


def parse_nkolay_date(value):
    if not value:
        return None

    # Örn: 20260508
    parsed = pd.to_datetime(value, format="%Y%m%d", errors="coerce")
    return parsed.date().isoformat() if pd.notna(parsed) else None


def normalize_transaction(t: Dict[str, Any]) -> Dict[str, Any]:
    return {
        "transaction_id": str(t.get("OID") or ""),
        "reference_code": str(t.get("REFERENCE_CODE") or ""),
        "client_reference_code": str(t.get("CLIENT_REFERENCE_CODE") or ""),
        "auth_code": str(t.get("AUTH_CODE") or ""),

        "transaction_date": parse_nkolay_datetime(t.get("TRX_DATE")),
        "valor_date": parse_nkolay_date(t.get("VALOR_DATE")),

        "transaction_type": str(t.get("TRANSACTION_TYPE") or ""),
        "status": str(t.get("STATUS") or ""),
        "description": str(t.get("DESCRIPTION") or ""),

        "transaction_amount": parse_amount(t.get("TRANSACTION_AMOUNT")),
        "authorization_amount": parse_amount(t.get("AUTHORIZATION_AMOUNT")),
        "commission_amount": parse_amount(t.get("COMMISION")),
        "merchant_commission_amount": parse_amount(t.get("MERCHANT_COMMISSION_AMOUNT")),

        "currency": "TRY",

        "card_number_masked": str(t.get("CARD_NUMBER") or ""),
        "card_holder_name": str(t.get("CARD_HOLDER_NAME") or ""),
        "card_bank_code": str(t.get("CARD_BANK_CODE") or ""),
        "card_bank_name": str(t.get("CARD_BANK_NAME") or ""),

        "pos_type": str(t.get("POS_TYPE") or ""),
        "terminal_name": str(t.get("TERMINAL_NAME") or ""),
        "is_3d": t.get("IS_3D"),
        "installment_count": str(t.get("INSTALLMENT_COUNT") or ""),

        "user_email": str(t.get("USER_EMAIL") or ""),
        "merchant_customer_no": str(t.get("MERCHANT_CUSTOMER_NO") or ""),

        "bank_result": str(t.get("BANK_RESULT") or ""),

        "source": "nkolay",
        "source_date": (
            parse_nkolay_datetime(t.get("TRX_DATE"))
            or parse_nkolay_date(t.get("VALOR_DATE"))
        ),
        "raw_json": json.dumps(t, ensure_ascii=False),
    }


# =============================
# BIGQUERY LOAD
# =============================
BQ_SCHEMA = [
    bigquery.SchemaField("transaction_id", "STRING"),
    bigquery.SchemaField("reference_code", "STRING"),
    bigquery.SchemaField("client_reference_code", "STRING"),
    bigquery.SchemaField("auth_code", "STRING"),
    bigquery.SchemaField("transaction_date", "TIMESTAMP"),
    bigquery.SchemaField("valor_date", "DATE"),
    bigquery.SchemaField("transaction_type", "STRING"),
    bigquery.SchemaField("status", "STRING"),
    bigquery.SchemaField("description", "STRING"),
    bigquery.SchemaField("transaction_amount", "FLOAT"),
    bigquery.SchemaField("authorization_amount", "FLOAT"),
    bigquery.SchemaField("commission_amount", "FLOAT"),
    bigquery.SchemaField("merchant_commission_amount", "FLOAT"),
    bigquery.SchemaField("currency", "STRING"),
    bigquery.SchemaField("card_number_masked", "STRING"),
    bigquery.SchemaField("card_holder_name", "STRING"),
    bigquery.SchemaField("card_bank_code", "STRING"),
    bigquery.SchemaField("card_bank_name", "STRING"),
    bigquery.SchemaField("pos_type", "STRING"),
    bigquery.SchemaField("terminal_name", "STRING"),
    bigquery.SchemaField("is_3d", "STRING"),
    bigquery.SchemaField("installment_count", "STRING"),
    bigquery.SchemaField("user_email", "STRING"),
    bigquery.SchemaField("merchant_customer_no", "STRING"),
    bigquery.SchemaField("bank_result", "STRING"),
    bigquery.SchemaField("source", "STRING"),
    bigquery.SchemaField("source_date", "DATE"),
    bigquery.SchemaField("raw_json", "STRING"),
    bigquery.SchemaField("etl_loaded_at", "TIMESTAMP"),
]

FLOAT_COLUMNS = [
    "transaction_amount",
    "authorization_amount",
    "commission_amount",
    "merchant_commission_amount",
]

STRING_COLUMNS = [
    "transaction_id",
    "reference_code",
    "client_reference_code",
    "auth_code",
    "transaction_type",
    "status",
    "description",
    "currency",
    "card_number_masked",
    "card_holder_name",
    "card_bank_code",
    "card_bank_name",
    "pos_type",
    "terminal_name",
    "is_3d",
    "installment_count",
    "user_email",
    "merchant_customer_no",
    "bank_result",
    "source",
    "raw_json",
]

TIMESTAMP_COLUMNS = [
    "transaction_date",
    "etl_loaded_at",
]


def prepare_bigquery_dataframe(df: pd.DataFrame, start_date: date) -> pd.DataFrame:
    df = df.copy()

    expected_columns = [field.name for field in BQ_SCHEMA]
    for col in expected_columns:
        if col not in df.columns:
            df[col] = None

    if df["source_date"].isna().all():
        df["source_date"] = start_date.isoformat()

    df["source_date"] = pd.to_datetime(df["source_date"], errors="coerce").dt.strftime("%Y-%m-%d")
    df["valor_date"] = pd.to_datetime(df["valor_date"], errors="coerce").dt.strftime("%Y-%m-%d")
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

    df_bq = prepare_bigquery_dataframe(df, start_date=start_date)
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

    payload = payment_list(start_date, end_date, client_ref_code="")
    transactions = extract_transactions(payload)

    print(f"[INFO] tx_count={len(transactions)}")

    if transactions:
        df = pd.DataFrame([normalize_transaction(t) for t in transactions])
    else:
        df = pd.DataFrame([{
            "source": "nkolay",
            "raw_json": json.dumps(payload, ensure_ascii=False),
        }])

    print(f"[OK] Rows fetched: {len(df)}")

    if WRITE_CSV:
        output_file = OUT_DIR / (
            f"nkolay_transactions_{args.mode}_{start_date.strftime('%Y%m%d')}_to_{end_date.strftime('%Y%m%d')}.csv"
        )
        df.to_csv(output_file, index=False, encoding="utf-8-sig")
        print(f"[OK] CSV saved: {output_file}")

    load_to_bigquery(df, start_date, end_date)
    print("[OK] N Kolay export completed")


if __name__ == "__main__":
    main()