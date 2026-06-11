import json
import argparse
import os
import tempfile
import time
import xml.etree.ElementTree as ET
from datetime import date, datetime, timedelta, timezone
from typing import Any, Dict, List, Optional

import pandas as pd
import requests
from dotenv import load_dotenv
from google.api_core.exceptions import NotFound
from google.cloud import bigquery


load_dotenv()

TCMB_BASE_URL = os.getenv("TCMB_BASE_URL", "https://www.tcmb.gov.tr/kurlar").rstrip("/")
TCMB_URL = os.getenv("TCMB_URL", f"{TCMB_BASE_URL}/today.xml")
DEBUG = os.getenv("DEBUG", "0").strip() == "1"

API_TIMEOUT_SECONDS = int(os.getenv("API_TIMEOUT_SECONDS", "120"))
API_MAX_RETRIES = int(os.getenv("API_MAX_RETRIES", "3"))
API_RETRY_SLEEP_SECONDS = int(os.getenv("API_RETRY_SLEEP_SECONDS", "5"))

WRITE_CSV = os.getenv("WRITE_CSV", "0").strip() == "1"
OUT_DIR = os.getenv("OUT_DIR", "./tcmb_outputs")

BQ_ENABLED = os.getenv("BQ_ENABLED", "1").strip() == "1"
BQ_PROJECT_ID = os.getenv("BQ_PROJECT_ID", "microgain-9f959").strip()
BQ_DATASET = os.getenv("BQ_DATASET", "bc_t").strip()
BQ_TABLE = os.getenv("BQ_TABLE", "tcmb_exchange_rates_raw").strip()

if WRITE_CSV:
    os.makedirs(OUT_DIR, exist_ok=True)


# =============================
# HELPERS
# =============================
def daterange(start_date: date, end_date: date):
    current = start_date
    while current <= end_date:
        yield current
        current += timedelta(days=1)


def to_float(value: Optional[str]) -> Optional[float]:
    if value is None:
        return None
    value = value.strip().replace(",", ".")
    if value == "":
        return None
    try:
        return float(value)
    except ValueError:
        return None


def to_int(value: Optional[str]) -> Optional[int]:
    if value is None:
        return None
    value = value.strip()
    if value == "":
        return None
    try:
        return int(value)
    except ValueError:
        return None


def parse_tcmb_date(date_str: Optional[str]) -> Optional[str]:
    if not date_str:
        return None
    try:
        return datetime.strptime(date_str, "%m/%d/%Y").date().isoformat()
    except ValueError:
        return None


def build_tcmb_url(target_date: Optional[date] = None) -> str:
    if target_date is None:
        return TCMB_URL

    # TCMB historical XML pattern:
    # https://www.tcmb.gov.tr/kurlar/YYYYMM/DDMMYYYY.xml
    return f"{TCMB_BASE_URL}/{target_date.strftime('%Y%m')}/{target_date.strftime('%d%m%Y')}.xml"


def fetch_tcmb_xml(target_date: Optional[date] = None) -> Optional[bytes]:
    url = build_tcmb_url(target_date)
    last_error = None

    for attempt in range(1, API_MAX_RETRIES + 1):
        try:
            response = requests.get(url, timeout=API_TIMEOUT_SECONDS)

            if DEBUG:
                print("URL:", url)
                print("STATUS:", response.status_code)
                print(response.text[:1000])

            if response.status_code == 404:
                print(f"[WARN] TCMB XML bulunamadı, gün atlanıyor: {url}")
                return None

            if response.status_code in (429, 500, 502, 503, 504):
                last_error = RuntimeError(f"Retryable TCMB API status={response.status_code}")
                sleep_s = API_RETRY_SLEEP_SECONDS * attempt
                print(
                    f"[WARN] TCMB retryable HTTP error: "
                    f"status={response.status_code} attempt={attempt}/{API_MAX_RETRIES} sleep={sleep_s}s url={url}"
                )
                time.sleep(sleep_s)
                continue

            response.raise_for_status()
            return response.content

        except (requests.exceptions.Timeout, requests.exceptions.ConnectionError) as e:
            last_error = e
            sleep_s = API_RETRY_SLEEP_SECONDS * attempt
            print(
                f"[WARN] TCMB timeout/connection error: "
                f"attempt={attempt}/{API_MAX_RETRIES} sleep={sleep_s}s err={type(e).__name__} url={url}"
            )
            time.sleep(sleep_s)

    raise RuntimeError(f"TCMB request failed after {API_MAX_RETRIES} attempts: {last_error}")


# =============================
# TCMB PARSE
# =============================
def get_tcmb_rates(target_date: Optional[date] = None) -> Optional[Dict[str, Any]]:
    source_url = build_tcmb_url(target_date)
    xml_content = fetch_tcmb_xml(target_date)

    if not xml_content:
        return None

    root = ET.fromstring(xml_content)

    result = {
        "rate_date": parse_tcmb_date(root.attrib.get("Date")),
        "requested_date": target_date.isoformat() if target_date else None,
        "date_tr": root.attrib.get("Tarih"),
        "bulletin_no": root.attrib.get("Bulten_No"),
        "source_url": source_url,
        "currencies": [],
    }

    for currency in root.findall("Currency"):
        item = {
            "rate_date": parse_tcmb_date(root.attrib.get("Date")),
            "requested_date": target_date.isoformat() if target_date else None,
            "date_tr": root.attrib.get("Tarih"),
            "bulletin_no": root.attrib.get("Bulten_No"),
            "source_url": source_url,
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
            "raw_json": json.dumps(
                {
                    "attributes": currency.attrib,
                    "children": {child.tag: child.text for child in currency},
                },
                ensure_ascii=False,
            ),
        }
        result["currencies"].append(item)

    return result


def rates_to_dataframe(data: Dict[str, Any]) -> pd.DataFrame:
    rows = data.get("currencies", [])
    df = pd.DataFrame(rows)

    if df.empty:
        return df

    df["etl_loaded_at"] = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S")
    return df


# =============================
# BIGQUERY LOAD
# =============================
BQ_SCHEMA = [
    bigquery.SchemaField("rate_date", "DATE"),
    bigquery.SchemaField("requested_date", "DATE"),
    bigquery.SchemaField("date_tr", "STRING"),
    bigquery.SchemaField("bulletin_no", "STRING"),
    bigquery.SchemaField("source_url", "STRING"),
    bigquery.SchemaField("cross_order", "INT64"),
    bigquery.SchemaField("kod", "STRING"),
    bigquery.SchemaField("currency_code", "STRING"),
    bigquery.SchemaField("unit", "INT64"),
    bigquery.SchemaField("name_tr", "STRING"),
    bigquery.SchemaField("name_en", "STRING"),
    bigquery.SchemaField("forex_buying", "FLOAT"),
    bigquery.SchemaField("forex_selling", "FLOAT"),
    bigquery.SchemaField("banknote_buying", "FLOAT"),
    bigquery.SchemaField("banknote_selling", "FLOAT"),
    bigquery.SchemaField("cross_rate_usd", "FLOAT"),
    bigquery.SchemaField("cross_rate_other", "FLOAT"),
    bigquery.SchemaField("raw_json", "STRING"),
    bigquery.SchemaField("etl_loaded_at", "TIMESTAMP"),
]

FLOAT_COLUMNS = [
    "forex_buying",
    "forex_selling",
    "banknote_buying",
    "banknote_selling",
    "cross_rate_usd",
    "cross_rate_other",
]

INTEGER_COLUMNS = [
    "cross_order",
    "unit",
]

DATE_COLUMNS = [
    "rate_date",
    "requested_date",
]

STRING_COLUMNS = [
    "date_tr",
    "bulletin_no",
    "source_url",
    "kod",
    "currency_code",
    "name_tr",
    "name_en",
    "raw_json",
]

TIMESTAMP_COLUMNS = [
    "etl_loaded_at",
]


def prepare_bigquery_dataframe(df: pd.DataFrame) -> pd.DataFrame:
    df = df.copy()

    expected_columns = [field.name for field in BQ_SCHEMA]
    for col in expected_columns:
        if col not in df.columns:
            df[col] = None

    for col in DATE_COLUMNS:
        df[col] = pd.to_datetime(df[col], errors="coerce").dt.strftime("%Y-%m-%d")

    for col in FLOAT_COLUMNS:
        df[col] = pd.to_numeric(df[col], errors="coerce")

    for col in INTEGER_COLUMNS:
        df[col] = pd.to_numeric(df[col], errors="coerce").astype("Int64")

    for col in TIMESTAMP_COLUMNS:
        df[col] = pd.to_datetime(df[col], errors="coerce", utc=True).dt.strftime("%Y-%m-%d %H:%M:%S")
        df[col] = df[col].replace("NaT", None)

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
            field="rate_date",
        )
        client.create_table(table)
        print(f"[BQ] Table created: {table_id}")


def delete_existing_bigquery_rows(client: bigquery.Client, table_id: str, rate_date: str) -> None:
    sql = f"""
    DELETE FROM `{table_id}`
    WHERE rate_date = @rate_date
    """
    job_config = bigquery.QueryJobConfig(
        query_parameters=[
            bigquery.ScalarQueryParameter("rate_date", "DATE", rate_date),
        ]
    )
    client.query(sql, job_config=job_config).result()
    print(f"[BQ] Existing rows deleted: {table_id} / rate_date={rate_date}")


def load_to_bigquery(df: pd.DataFrame) -> None:
    if not BQ_ENABLED:
        print("[BQ] BQ_ENABLED=0, BigQuery load atlandı.")
        return

    if df.empty:
        print("[BQ] Empty dataframe, load atlandı.")
        return

    df_bq = prepare_bigquery_dataframe(df)
    rate_dates = sorted({x for x in df_bq["rate_date"].dropna().unique().tolist()})

    if not rate_dates:
        raise RuntimeError("TCMB rate_date bulunamadı, BigQuery load iptal edildi.")

    table_id = f"{BQ_PROJECT_ID}.{BQ_DATASET}.{BQ_TABLE}"
    client = bigquery.Client(project=BQ_PROJECT_ID)
    ensure_bigquery_table(client, table_id)

    for rate_date in rate_dates:
        delete_existing_bigquery_rows(client, table_id, rate_date)

    rows = sanitize_rows_for_bigquery(df_bq.to_dict(orient="records"))

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


# =============================
# MAIN
# =============================
def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "mode",
        nargs="?",
        default="daily",
        choices=["daily", "today", "custom"],
        help="daily/today: TCMB today.xml çeker. custom: --date veya --start-date/--end-date ile tarihli XML çeker.",
    )
    parser.add_argument("--date", help="Tek tarih: YYYY-MM-DD")
    parser.add_argument("--start-date", help="Başlangıç tarihi: YYYY-MM-DD")
    parser.add_argument("--end-date", help="Bitiş tarihi: YYYY-MM-DD")
    return parser.parse_args()


def resolve_target_dates(args) -> List[Optional[date]]:
    if args.mode in ("daily", "today"):
        return [None]

    if args.date:
        return [date.fromisoformat(args.date)]

    if args.start_date and args.end_date:
        start_date = date.fromisoformat(args.start_date)
        end_date = date.fromisoformat(args.end_date)
        return list(daterange(start_date, end_date))

    raise ValueError("custom mode için --date veya --start-date/--end-date verilmelidir.")


def main() -> None:
    args = parse_args()
    target_dates = resolve_target_dates(args)

    all_frames = []

    for target_date in target_dates:
        data = get_tcmb_rates(target_date)

        if not data:
            continue

        df = rates_to_dataframe(data)
        all_frames.append(df)

        print("Tarih:", data.get("rate_date"))
        print("İstenen Tarih:", data.get("requested_date"))
        print("Bülten No:", data.get("bulletin_no"))
        print("[OK] Rows fetched:", len(df))

        if WRITE_CSV:
            output_file = os.path.join(
                OUT_DIR,
                f"tcmb_exchange_rates_{data.get('rate_date') or datetime.now().date().isoformat()}.csv",
            )
            df.to_csv(output_file, index=False, encoding="utf-8-sig")
            print(f"[OK] CSV saved: {output_file}")

    if not all_frames:
        print("[WARN] Yüklenecek TCMB datası bulunamadı.")
        return

    final_df = pd.concat(all_frames, ignore_index=True)
    load_to_bigquery(final_df)
    print("[OK] TCMB export completed")


if __name__ == "__main__":
    main()