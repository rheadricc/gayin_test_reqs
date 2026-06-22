import os
import json
import time
import hmac
import base64
import hashlib
import secrets
import argparse
from pathlib import Path
import tempfile
from datetime import UTC, date, datetime, timedelta
from typing import Any, Dict, List, Optional
from google.api_core.exceptions import NotFound

import pandas as pd
import requests
from google.cloud import bigquery
from dotenv import load_dotenv


# =============================
# ENV
# =============================
load_dotenv(dotenv_path=Path(__file__).resolve().parent / ".env")

IYZICO_BASE_URL = os.getenv("IYZICO_BASE_URL", "https://api.iyzipay.com").rstrip("/")
IYZICO_API_KEY = os.getenv("IYZICO_API_KEY", "").strip()
IYZICO_SECRET_KEY = os.getenv("IYZICO_SECRET_KEY", "").strip()

OUT_DIR = Path(os.getenv("OUT_DIR", "./iyzico_outputs"))
DEBUG = os.getenv("DEBUG", "0").strip() == "1"
API_TIMEOUT_SECONDS = int(os.getenv("API_TIMEOUT_SECONDS", "120"))
API_MAX_RETRIES = int(os.getenv("API_MAX_RETRIES", "3"))
API_RETRY_SLEEP_SECONDS = int(os.getenv("API_RETRY_SLEEP_SECONDS", "5"))

WRITE_CSV = os.getenv("WRITE_CSV", "0").strip() == "1"
BQ_ENABLED = os.getenv("BQ_ENABLED", "1").strip() == "1"
BQ_PROJECT_ID = os.getenv("BQ_PROJECT_ID", "microgain-9f959").strip()
BQ_DATASET = os.getenv("BQ_DATASET", "bc_t").strip()

BQ_TABLE = os.getenv("BQ_TABLE", "iyzico_transactions_raw").strip()
BQ_INSERT_BATCH_SIZE = int(os.getenv("BQ_INSERT_BATCH_SIZE", "500"))

if WRITE_CSV:
    OUT_DIR.mkdir(parents=True, exist_ok=True)

if not IYZICO_API_KEY or not IYZICO_SECRET_KEY:
    raise RuntimeError(
        "Eksik env var:\n"
        "  IYZICO_API_KEY=...\n"
        "  IYZICO_SECRET_KEY=...\n"
        "  IYZICO_BASE_URL=https://api.iyzipay.com\n"
    )


S = requests.Session()
S.headers.update({
    "Content-Type": "application/json",
    "Accept": "application/json",
})


# =============================
# IYZWSv2 SIGNING
# =============================
def random_key() -> str:
    ms = int(time.time() * 1000)
    r = secrets.randbelow(10**10)
    return f"{ms}{r:010d}"


def compact_json(obj: Dict[str, Any]) -> str:
    return json.dumps(obj, ensure_ascii=False, separators=(",", ":"))


def iyzws_headers(uri_path: str, body_obj: Optional[Dict[str, Any]] = None) -> Dict[str, str]:
    rnd = random_key()
    body_str = "" if body_obj is None else compact_json(body_obj)
    payload = f"{rnd}{uri_path}{body_str}"

    signature = hmac.new(
        IYZICO_SECRET_KEY.encode("utf-8"),
        payload.encode("utf-8"),
        hashlib.sha256,
    ).hexdigest()

    auth_string = f"apiKey:{IYZICO_API_KEY}&randomKey:{rnd}&signature:{signature}"
    encoded_auth = base64.b64encode(auth_string.encode("utf-8")).decode("utf-8")

    return {
        "Authorization": f"IYZWSv2 {encoded_auth}",
        "x-iyzi-rnd": rnd,
        "Content-Type": "application/json",
        "Accept": "application/json",
    }


# =============================
# API
# =============================
def get_daily_transactions(day_iso: str, page: int = 1, locale: str = "tr") -> Dict[str, Any]:
    uri = "/v2/reporting/payment/transactions"
    url = f"{IYZICO_BASE_URL}{uri}"

    params = {
        "transactionDate": day_iso,
        "page": page,
        "locale": locale,
    }

    last_error = None

    for attempt in range(1, API_MAX_RETRIES + 1):
        try:
            resp = S.get(
                url,
                params=params,
                headers=iyzws_headers(uri),
                timeout=API_TIMEOUT_SECONDS,
            )

            if DEBUG:
                print("URL:", resp.url)
                print("STATUS:", resp.status_code)
                print(resp.text[:2000])

            resp.raise_for_status()
            return resp.json()

        except (requests.exceptions.Timeout, requests.exceptions.ConnectionError) as e:
            last_error = e
            sleep_s = API_RETRY_SLEEP_SECONDS * attempt
            print(
                f"[WARN] Iyzico API timeout/connection error: "
                f"date={day_iso} page={page} attempt={attempt}/{API_MAX_RETRIES} "
                f"sleep={sleep_s}s err={type(e).__name__}"
            )
            time.sleep(sleep_s)

        except requests.exceptions.HTTPError as e:
            status_code = e.response.status_code if e.response is not None else None
            last_error = e

            if status_code in (429, 500, 502, 503, 504):
                sleep_s = API_RETRY_SLEEP_SECONDS * attempt
                print(
                    f"[WARN] Iyzico API retryable HTTP error: "
                    f"date={day_iso} page={page} status={status_code} "
                    f"attempt={attempt}/{API_MAX_RETRIES} sleep={sleep_s}s"
                )
                time.sleep(sleep_s)
                continue

            raise

    raise RuntimeError(
        f"Iyzico API request failed after {API_MAX_RETRIES} attempts: "
        f"date={day_iso} page={page} error={last_error}"
    )


def extract_transactions(payload: Dict[str, Any]) -> List[Dict[str, Any]]:
    if isinstance(payload.get("transactions"), list):
        return payload["transactions"]

    data = payload.get("data")
    if isinstance(data, dict) and isinstance(data.get("transactions"), list):
        return data["transactions"]

    return []


def has_more(payload: Dict[str, Any], current_page: int, txs: List[Dict[str, Any]]) -> bool:
    meta = payload.get("meta") or payload.get("pagination") or payload.get("pageInfo")

    if isinstance(meta, dict):
        page_count = meta.get("pageCount") or meta.get("totalPage") or meta.get("totalPages")
        if isinstance(page_count, int):
            return current_page < page_count

    return len(txs) > 0


# =============================
# NORMALIZATION
# =============================
def normalize_transaction(t: Dict[str, Any], report_date: str) -> Dict[str, Any]:
    """
    Iyzico'dan gelen ham transaction JSON'unu
    BigQuery/CSV için sabit kolon formatına çevirir.
    """

    transaction_id = (
        t.get("transactionId")
        or t.get("paymentTransactionId")
        or t.get("iyziTransactionId")
    )

    payment_tx_id = t.get("paymentTxId")

    transaction_date = (
        t.get("transactionDate")
        or t.get("createdDate")
        or report_date
    )

    transaction_type = (
        t.get("transactionType")
        or t.get("type")
    )

    transaction_status = (
        t.get("transactionStatus")
        or t.get("paymentStatus")
        or t.get("status")
    )

    currency = (
        t.get("transactionCurrency")
        or t.get("currency")
        or t.get("currencyCode")
        or t.get("paidCurrency")
        or t.get("settlementCurrency")
    )

    amount = (
        t.get("paidPrice")
        or t.get("price")
        or t.get("amount")
        or t.get("paymentAmount")
    )

    return {
        # Ana kimlikler
        "transaction_id": str(transaction_id or ""),
        "payment_tx_id": str(payment_tx_id or ""),
        "payment_id": str(t.get("paymentId") or ""),
        "conversation_id": str(t.get("conversationId") or ""),
        "basket_id": str(t.get("basketId") or ""),

        # Tarihler
        "transaction_date": transaction_date,
        "report_date": report_date,

        # Durum / tip
        "transaction_type": str(transaction_type or ""),
        "transaction_status": str(transaction_status or ""),
        "payment_phase": t.get("paymentPhase"),
        "after_settlement": t.get("afterSettlement"),

        # Tutar / para birimi
        "price": t.get("price"),
        "paid_price": t.get("paidPrice"),
        "amount": amount,
        "transaction_currency": t.get("transactionCurrency"),
        "settlement_currency": t.get("settlementCurrency"),
        "currency": currency,

        # Taksit / 3DS
        "installment": t.get("installment"),
        "three_ds": t.get("threeDS"),

        # Iyzico komisyon / payout alanları
        "iyzico_commission": t.get("iyzicoCommission"),
        "iyzico_fee": t.get("iyzicoFee"),
        "merchant_payout_amount": t.get("merchantPayoutAmount"),
        "sub_merchant_payout_amount": t.get("subMerchantPayoutAmount"),
        "parity": t.get("parity"),
        "iyzico_conversion_amount": t.get("iyzicoConversionAmount"),

        # POS / banka referansları
        "connector_type": t.get("connectorType") or t.get("connector"),
        "pos_order_id": t.get("posOrderId"),
        "auth_code": t.get("authCode"),
        "host_reference": t.get("hostReference"),

        # Ham veri
        "raw_json": json.dumps(t, ensure_ascii=False),
    }


# =============================
# EXPORT
# =============================
def daterange(start: date, end: date):
    d = start
    while d <= end:
        yield d
        d += timedelta(days=1)


def fetch_transactions(start_date: date, end_date: date) -> pd.DataFrame:
    rows: List[Dict[str, Any]] = []

    print(f"[INFO] Iyzico transactions çekiliyor: {start_date}..{end_date}")

    for d in daterange(start_date, end_date):
        day_iso = d.isoformat()
        page = 1

        while True:
            payload = get_daily_transactions(day_iso, page=page, locale="tr")
            txs = extract_transactions(payload)

            print(f"[INFO] {day_iso} page={page} tx_count={len(txs)}")

            for tx in txs:
                rows.append(normalize_transaction(tx, report_date=day_iso))

            if not has_more(payload, page, txs):
                break

            page += 1

    return pd.DataFrame(rows)


# =============================
# BIGQUERY LOAD
# =============================
BQ_SCHEMA = [
    bigquery.SchemaField("transaction_id", "STRING"),
    bigquery.SchemaField("payment_tx_id", "STRING"),
    bigquery.SchemaField("payment_id", "STRING"),
    bigquery.SchemaField("conversation_id", "STRING"),
    bigquery.SchemaField("basket_id", "STRING"),
    bigquery.SchemaField("transaction_date", "STRING"),
    bigquery.SchemaField("report_date", "DATE"),
    bigquery.SchemaField("transaction_type", "STRING"),
    bigquery.SchemaField("transaction_status", "STRING"),
    bigquery.SchemaField("payment_phase", "STRING"),
    bigquery.SchemaField("after_settlement", "STRING"),
    bigquery.SchemaField("price", "FLOAT"),
    bigquery.SchemaField("paid_price", "FLOAT"),
    bigquery.SchemaField("amount", "FLOAT"),
    bigquery.SchemaField("transaction_currency", "STRING"),
    bigquery.SchemaField("settlement_currency", "STRING"),
    bigquery.SchemaField("currency", "STRING"),
    bigquery.SchemaField("installment", "INTEGER"),
    bigquery.SchemaField("three_ds", "STRING"),
    bigquery.SchemaField("iyzico_commission", "FLOAT"),
    bigquery.SchemaField("iyzico_fee", "FLOAT"),
    bigquery.SchemaField("merchant_payout_amount", "FLOAT"),
    bigquery.SchemaField("sub_merchant_payout_amount", "FLOAT"),
    bigquery.SchemaField("parity", "FLOAT"),
    bigquery.SchemaField("iyzico_conversion_amount", "FLOAT"),
    bigquery.SchemaField("connector_type", "STRING"),
    bigquery.SchemaField("pos_order_id", "STRING"),
    bigquery.SchemaField("auth_code", "STRING"),
    bigquery.SchemaField("host_reference", "STRING"),
    bigquery.SchemaField("raw_json", "STRING"),
    bigquery.SchemaField("etl_loaded_at", "TIMESTAMP"),
]


FLOAT_COLUMNS = [
    "price",
    "paid_price",
    "amount",
    "iyzico_commission",
    "iyzico_fee",
    "merchant_payout_amount",
    "sub_merchant_payout_amount",
    "parity",
    "iyzico_conversion_amount",
]


STRING_COLUMNS = [
    "transaction_id",
    "payment_tx_id",
    "payment_id",
    "conversation_id",
    "basket_id",
    "transaction_date",
    "transaction_type",
    "transaction_status",
    "payment_phase",
    "after_settlement",
    "transaction_currency",
    "settlement_currency",
    "currency",
    "three_ds",
    "connector_type",
    "pos_order_id",
    "auth_code",
    "host_reference",
    "raw_json",
]


def prepare_bigquery_dataframe(df: pd.DataFrame) -> pd.DataFrame:
    df = df.copy()

    expected_columns = [field.name for field in BQ_SCHEMA]
    for col in expected_columns:
        if col not in df.columns:
            df[col] = None

    df["report_date"] = pd.to_datetime(df["report_date"], errors="coerce").dt.strftime("%Y-%m-%d")
    df["etl_loaded_at"] = datetime.now(UTC).isoformat()

    for col in FLOAT_COLUMNS:
        df[col] = pd.to_numeric(df[col], errors="coerce")

    df["installment"] = pd.to_numeric(df["installment"], errors="coerce").astype("Int64")

    for col in STRING_COLUMNS:
        df[col] = df[col].where(pd.notna(df[col]), None)
        df[col] = df[col].apply(lambda x: None if x is None else str(x))

    df = df[expected_columns]
    df = df.where(pd.notna(df), None)
    return df


def sanitize_rows_for_bigquery(rows: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
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
            field="report_date",
        )
        client.create_table(table)
        print(f"[BQ] Table created: {table_id}")


def delete_existing_bigquery_rows(client: bigquery.Client, table_id: str, start_date: date, end_date: date) -> None:
    sql = f"""
    DELETE FROM `{table_id}`
    WHERE report_date BETWEEN @start_date AND @end_date
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


def resolve_dates(mode: str, start_arg: Optional[str], end_arg: Optional[str]):
    today = datetime.now(UTC).date()
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


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "mode",
        choices=["daily", "manual", "monthly", "custom"],
        help="daily=T-1, manual=ay başı..T-1, monthly=önceki ay, custom=tarih aralığı",
    )
    parser.add_argument("--start-date", help="YYYY-MM-DD")
    parser.add_argument("--end-date", help="YYYY-MM-DD")
    parser.add_argument(
        "--csv-only",
        action="store_true",
        help="Sadece CSV çıktı üretir; BigQuery yüklemesini kapatır.",
    )
    parser.add_argument(
        "--write-csv",
        action="store_true",
        help="CSV çıktı üretimini aktif eder.",
    )
    parser.add_argument(
        "--no-bq",
        action="store_true",
        help="BigQuery yüklemesini kapatır.",
    )
    args = parser.parse_args()

    global WRITE_CSV, BQ_ENABLED
    if args.csv_only:
        WRITE_CSV = True
        BQ_ENABLED = False
    if args.write_csv:
        WRITE_CSV = True
    if args.no_bq:
        BQ_ENABLED = False

    if WRITE_CSV:
        OUT_DIR.mkdir(parents=True, exist_ok=True)

    start_date, end_date = resolve_dates(args.mode, args.start_date, args.end_date)

    df = fetch_transactions(start_date, end_date)

    print(f"[OK] Rows fetched: {len(df)}")

    if WRITE_CSV:
        output_file = OUT_DIR / (
            f"iyzico_transactions_{args.mode}_{start_date.strftime('%Y%m%d')}_to_{end_date.strftime('%Y%m%d')}.csv"
        )
        df.to_csv(output_file, index=False, encoding="utf-8-sig")
        print(f"[OK] CSV saved: {output_file}")
    else:
        print("[CSV] WRITE_CSV=0 ve --write-csv/--csv-only verilmediği için CSV yazılmadı.")

    load_to_bigquery(df, start_date, end_date)
    print("[OK] Iyzico export completed")


if __name__ == "__main__":
    main()