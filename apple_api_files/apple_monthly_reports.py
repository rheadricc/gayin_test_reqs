"""
Apple App Store Connect Subscriber Report exporter.

Daily mode requests the fixed T-1 report date. Monthly mode is retained for
historical backfills.
"""

import argparse
import calendar
import csv
import gzip
import json
import os
import sys
import time
from datetime import date, datetime, timedelta, timezone
from decimal import Decimal, InvalidOperation
from pathlib import Path
from uuid import uuid4

import jwt
import pandas as pd
import requests
from dotenv import load_dotenv
from google.api_core.exceptions import NotFound
from google.cloud import bigquery
from google.oauth2 import service_account


load_dotenv(dotenv_path=Path(__file__).resolve().parent / ".env", override=False)

DEFAULT_CONNECT_ISSUER_ID = "203234da-b081-42db-88a4-de4b9d0fc6e1"
DEFAULT_CONNECT_KEY_ID = "3JUWC66S52"
DEFAULT_PRIVATE_KEY_PATH = (
    "/Users/batuhancakir/Downloads/"
    "AuthKey_3JUWC66S52_app_store_connect_api_token.p8"
)
DEFAULT_VENDOR_NUMBER = "89408638"

BASE_DIR = Path(__file__).resolve().parent
DEFAULT_OUTPUT_DIR = BASE_DIR / "applereports"

# Historical backfill defaults. The local change from May to March is preserved.
START_YEAR = 2026
START_MONTH = 3

REPORT_URL = "https://api.appstoreconnect.apple.com/v1/salesReports"
REPORT_VERSION = "1_3"
MAX_DAILY_LOOKBACK = 7

APPLE_FIELDS = [
    "Event Date",
    "App Name",
    "App Apple ID",
    "Subscription Name",
    "Subscription Apple ID",
    "Subscription Group ID",
    "Standard Subscription Duration",
    "Subscription Offer Name",
    "Promotional Offer ID",
    "Subscription Offer Type",
    "Subscription Offer Duration",
    "Marketing Opt-In Duration",
    "Customer Price",
    "Customer Currency",
    "Developer Proceeds",
    "Proceeds Currency",
    "Preserved Pricing",
    "Proceeds Reason",
    "Client",
    "Device",
    "Country",
    "Subscriber ID",
    "Subscriber ID Reset",
    "Refund",
    "Purchase Date",
    "Units",
]

OUTPUT_FIELDS = [
    "source_report_date",
    "export_loaded_at_utc",
    *APPLE_FIELDS,
]

APPLE_COLUMN_MAP = {
    "source_report_date": "source_report_date",
    "export_loaded_at_utc": "export_loaded_at_utc",
    "Event Date": "event_date",
    "App Name": "app_name",
    "App Apple ID": "app_apple_id",
    "Subscription Name": "subscription_name",
    "Subscription Apple ID": "subscription_apple_id",
    "Subscription Group ID": "subscription_group_id",
    "Standard Subscription Duration": "standard_subscription_duration",
    "Subscription Offer Name": "subscription_offer_name",
    "Promotional Offer ID": "promotional_offer_id",
    "Subscription Offer Type": "subscription_offer_type",
    "Subscription Offer Duration": "subscription_offer_duration",
    "Marketing Opt-In Duration": "marketing_opt_in_duration",
    "Customer Price": "customer_price",
    "Customer Currency": "customer_currency",
    "Developer Proceeds": "developer_proceeds",
    "Proceeds Currency": "proceeds_currency",
    "Preserved Pricing": "preserved_pricing",
    "Proceeds Reason": "proceeds_reason",
    "Client": "client",
    "Device": "device",
    "Country": "country",
    "Subscriber ID": "subscriber_id",
    "Subscriber ID Reset": "subscriber_id_reset",
    "Refund": "refund",
    "Purchase Date": "purchase_date",
    "Units": "units",
}

APPLE_BQ_SCHEMA = [
    bigquery.SchemaField("source_report_date", "DATE"),
    bigquery.SchemaField("export_loaded_at_utc", "TIMESTAMP"),
    bigquery.SchemaField("event_date", "DATE"),
    bigquery.SchemaField("app_name", "STRING"),
    bigquery.SchemaField("app_apple_id", "STRING"),
    bigquery.SchemaField("subscription_name", "STRING"),
    bigquery.SchemaField("subscription_apple_id", "STRING"),
    bigquery.SchemaField("subscription_group_id", "STRING"),
    bigquery.SchemaField("standard_subscription_duration", "STRING"),
    bigquery.SchemaField("subscription_offer_name", "STRING"),
    bigquery.SchemaField("promotional_offer_id", "STRING"),
    bigquery.SchemaField("subscription_offer_type", "STRING"),
    bigquery.SchemaField("subscription_offer_duration", "STRING"),
    bigquery.SchemaField("marketing_opt_in_duration", "STRING"),
    bigquery.SchemaField("customer_price", "NUMERIC"),
    bigquery.SchemaField("customer_currency", "STRING"),
    bigquery.SchemaField("developer_proceeds", "NUMERIC"),
    bigquery.SchemaField("proceeds_currency", "STRING"),
    bigquery.SchemaField("preserved_pricing", "STRING"),
    bigquery.SchemaField("proceeds_reason", "STRING"),
    bigquery.SchemaField("client", "STRING"),
    bigquery.SchemaField("device", "STRING"),
    bigquery.SchemaField("country", "STRING"),
    bigquery.SchemaField("subscriber_id", "STRING"),
    bigquery.SchemaField("subscriber_id_reset", "STRING"),
    bigquery.SchemaField("refund", "STRING"),
    bigquery.SchemaField("purchase_date", "DATE"),
    bigquery.SchemaField("units", "NUMERIC"),
]


def get_config():
    running_in_airflow = env_flag("RUNNING_IN_AIRFLOW") or bool(
        os.getenv("AIRFLOW_CTX_DAG_ID")
    )
    write_csv = env_flag("WRITE_CSV", default=True) and not running_in_airflow
    bq_enabled = (
        running_in_airflow
        or not write_csv
        or env_flag("BQ_ENABLED", default=False)
    )
    return {
        "issuer_id": os.getenv(
            "APPLE_CONNECT_ISSUER_ID",
            DEFAULT_CONNECT_ISSUER_ID,
        ),
        "key_id": os.getenv(
            "APPLE_CONNECT_KEY_ID",
            DEFAULT_CONNECT_KEY_ID,
        ),
        "private_key_path": os.getenv(
            "APPLE_CONNECT_PRIVATE_KEY_PATH",
            DEFAULT_PRIVATE_KEY_PATH,
        ),
        "private_key": os.getenv("APPLE_CONNECT_PRIVATE_KEY", "").strip(),
        "vendor_number": os.getenv(
            "APPLE_VENDOR_NUMBER",
            DEFAULT_VENDOR_NUMBER,
        ),
        "output_dir": Path(
            os.getenv("APPLE_REPORT_OUTPUT_DIR", str(DEFAULT_OUTPUT_DIR))
        ),
        "write_csv": write_csv,
        "bq_enabled": bq_enabled,
        "bq_project_id": os.getenv("BQ_PROJECT_ID", "microgain-9f959").strip(),
        "bq_dataset": os.getenv("BQ_DATASET", "bc_t").strip(),
        "bq_table": os.getenv(
            "BQ_TABLE",
            "apple_transactions_raw",
        ).strip(),
        "bq_service_account_json": os.getenv(
            "BQ_SERVICE_ACCOUNT_JSON",
            "",
        ).strip(),
        "running_in_airflow": running_in_airflow,
    }


def env_flag(name, default=False):
    default_value = "1" if default else "0"
    return os.getenv(name, default_value).strip().lower() in {
        "1",
        "true",
        "yes",
        "on",
    }


def parse_date(value):
    try:
        return datetime.strptime(value, "%Y-%m-%d").date()
    except ValueError as exc:
        raise argparse.ArgumentTypeError(
            f"Geçersiz tarih: {value}. Beklenen format YYYY-MM-DD."
        ) from exc


def generate_token(config):
    private_key = config["private_key"]
    if not private_key:
        private_key_path = Path(config["private_key_path"])
        if not private_key_path.is_file():
            raise FileNotFoundError(
                "Apple private key bulunamadı. "
                "APPLE_CONNECT_PRIVATE_KEY veya "
                "APPLE_CONNECT_PRIVATE_KEY_PATH ayarlanmalı."
            )
        private_key = private_key_path.read_text()
    now = int(time.time())
    payload = {
        "iss": config["issuer_id"],
        "iat": now,
        "exp": now + 1200,
        "aud": "appstoreconnect-v1",
    }
    headers = {
        "alg": "ES256",
        "kid": config["key_id"],
        "typ": "JWT",
    }
    return jwt.encode(payload, private_key, algorithm="ES256", headers=headers)


def download_subscriber_report(report_date, token, vendor_number):
    params = {
        "filter[reportType]": "SUBSCRIBER",
        "filter[reportSubType]": "DETAILED",
        "filter[frequency]": "DAILY",
        "filter[vendorNumber]": vendor_number,
        "filter[reportDate]": report_date.isoformat(),
        "filter[version]": REPORT_VERSION,
    }
    response = requests.get(
        REPORT_URL,
        headers={"Authorization": f"Bearer {token}"},
        params=params,
        timeout=120,
    )
    response.raise_for_status()

    content = gzip.decompress(response.content).decode("utf-8")
    rows = list(csv.DictReader(content.splitlines(), delimiter="\t"))
    loaded_at = datetime.now(timezone.utc).isoformat()
    for row in rows:
        row["source_report_date"] = report_date.isoformat()
        row["export_loaded_at_utc"] = loaded_at
    return rows


def find_latest_available_report(
    target_date,
    config,
    allow_fallback=True,
    max_lookback=MAX_DAILY_LOOKBACK,
):
    token = generate_token(config)
    attempts = max_lookback + 1 if allow_fallback else 1

    for offset in range(attempts):
        report_date = target_date - timedelta(days=offset)
        try:
            rows = download_subscriber_report(
                report_date,
                token,
                config["vendor_number"],
            )
            if offset:
                print(
                    f"Requested date {target_date} is not available; "
                    f"using latest completed report date {report_date}."
                )
            return report_date, rows
        except requests.HTTPError as exc:
            if exc.response.status_code != 404:
                raise
            print(f"Apple report {report_date}: not available (404)")

    raise RuntimeError(
        f"Apple report bulunamadı. Hedef={target_date}, "
        f"lookback={max_lookback} gün."
    )


def write_csv(rows, output_file):
    if not rows:
        raise RuntimeError(f"Yazılacak Apple satırı yok: {output_file}")

    output_file.parent.mkdir(parents=True, exist_ok=True)
    with output_file.open("w", newline="", encoding="utf-8") as csv_file:
        writer = csv.DictWriter(
            csv_file,
            fieldnames=OUTPUT_FIELDS,
            extrasaction="ignore",
        )
        writer.writeheader()
        writer.writerows(rows)
    return len(rows)


def clean_string(value):
    if value is None or pd.isna(value):
        return None
    text = str(value).strip()
    return text or None


def clean_decimal(value):
    text = clean_string(value)
    if not text:
        return None
    try:
        return str(Decimal(text.replace(",", "")))
    except InvalidOperation:
        raise ValueError(f"Sayısal Apple değeri parse edilemedi: {value}")


def prepare_bigquery_rows(rows):
    decimal_columns = {"customer_price", "developer_proceeds", "units"}
    date_columns = {"source_report_date", "event_date", "purchase_date"}
    timestamp_columns = {"export_loaded_at_utc"}
    schema_names = [field.name for field in APPLE_BQ_SCHEMA]

    prepared_rows = []
    for row in rows:
        normalized = {
            target: row.get(source)
            for source, target in APPLE_COLUMN_MAP.items()
        }
        clean_row = {}
        for column in schema_names:
            value = normalized.get(column)
            if column in decimal_columns:
                clean_row[column] = clean_decimal(value)
            elif column in date_columns:
                text = clean_string(value)
                clean_row[column] = date.fromisoformat(text).isoformat() if text else None
            elif column in timestamp_columns:
                text = clean_string(value)
                clean_row[column] = (
                    pd.to_datetime(text, utc=True).isoformat() if text else None
                )
            else:
                clean_row[column] = clean_string(value)
        prepared_rows.append(clean_row)
    return prepared_rows


def load_service_account_credentials(value):
    raw_value = value.strip()
    scopes = ["https://www.googleapis.com/auth/cloud-platform"]
    if raw_value.startswith("{"):
        return service_account.Credentials.from_service_account_info(
            json.loads(raw_value),
            scopes=scopes,
        )

    credentials_path = Path(raw_value)
    if not credentials_path.is_file():
        raise FileNotFoundError(
            f"BigQuery service-account JSON bulunamadı: {credentials_path}"
        )
    return service_account.Credentials.from_service_account_file(
        credentials_path,
        scopes=scopes,
    )


def get_bigquery_client(config):
    credentials_value = (
        config["bq_service_account_json"]
        or os.getenv("GOOGLE_APPLICATION_CREDENTIALS", "").strip()
    )
    if credentials_value:
        credentials = load_service_account_credentials(credentials_value)
        return bigquery.Client(
            project=config["bq_project_id"],
            credentials=credentials,
        )
    return bigquery.Client(project=config["bq_project_id"])


def ensure_bigquery_table(client, table_id):
    try:
        client.get_table(table_id)
    except NotFound:
        table = bigquery.Table(table_id, schema=APPLE_BQ_SCHEMA)
        table.time_partitioning = bigquery.TimePartitioning(
            type_=bigquery.TimePartitioningType.DAY,
            field="source_report_date",
        )
        client.create_table(table)
        print(f"[BQ] Table created: {table_id}")


def load_to_bigquery(rows, start_date, end_date, config):
    prepared_rows = prepare_bigquery_rows(rows)
    if not prepared_rows:
        raise RuntimeError("BigQuery'ye yüklenecek Apple satırı yok.")

    table_id = (
        f"{config['bq_project_id']}."
        f"{config['bq_dataset']}."
        f"{config['bq_table']}"
    )
    staging_table_id = f"{table_id}__staging_{uuid4().hex}"
    client = get_bigquery_client(config)
    ensure_bigquery_table(client, table_id)

    staging_config = bigquery.LoadJobConfig(
        schema=APPLE_BQ_SCHEMA,
        write_disposition=bigquery.WriteDisposition.WRITE_TRUNCATE,
    )
    client.load_table_from_json(
        prepared_rows,
        staging_table_id,
        job_config=staging_config,
    ).result()

    try:
        sql = f"""
        BEGIN TRANSACTION;
        DELETE FROM `{table_id}`
        WHERE source_report_date BETWEEN @start_date AND @end_date;
        INSERT INTO `{table_id}`
        SELECT * FROM `{staging_table_id}`;
        COMMIT TRANSACTION;
        """
        job_config = bigquery.QueryJobConfig(
            query_parameters=[
                bigquery.ScalarQueryParameter(
                    "start_date",
                    "DATE",
                    start_date.isoformat(),
                ),
                bigquery.ScalarQueryParameter(
                    "end_date",
                    "DATE",
                    end_date.isoformat(),
                ),
            ]
        )
        client.query(sql, job_config=job_config).result()
    finally:
        client.delete_table(staging_table_id, not_found_ok=True)

    print(f"[BQ] Loaded rows: {len(prepared_rows)} -> {table_id}")


def write_outputs(rows, output_file, start_date, end_date, config):
    if config["write_csv"]:
        count = write_csv(rows, output_file)
        print(f"[CSV] {count} rows -> {output_file}")
    else:
        print("[CSV] WRITE_CSV=0 veya Airflow ortamı; CSV yazılmadı.")

    if config["bq_enabled"]:
        load_to_bigquery(rows, start_date, end_date, config)
    else:
        print("[BQ] Lokal CSV modu; BigQuery yüklemesi atlandı.")


def export_daily(requested_date=None, allow_fallback=False):
    config = get_config()
    target_date = requested_date or (
        datetime.now(timezone.utc).date() - timedelta(days=1)
    )
    report_date, rows = find_latest_available_report(
        target_date,
        config,
        allow_fallback=allow_fallback,
    )

    output_file = config["output_dir"] / (
        f"apple_subscriber_daily_{report_date:%Y%m%d}.csv"
    )
    write_outputs(
        rows,
        output_file,
        report_date,
        report_date,
        config,
    )

    refund_count = sum(row.get("Refund") == "Yes" for row in rows)
    unique_subscribers = len(
        {
            row.get("Subscriber ID")
            for row in rows
            if row.get("Subscriber ID")
        }
    )
    print(f"Report date: {report_date}")
    print(f"Rows: {len(rows)}")
    print(f"Unique subscriber IDs: {unique_subscribers}")
    print(f"Refund rows: {refund_count}")
    return {
        "platform": "Apple App Store",
        "target_date": report_date.isoformat(),
        "row_count": len(rows),
        "table_id": (
            f"{config['bq_project_id']}."
            f"{config['bq_dataset']}."
            f"{config['bq_table']}"
        ),
        "csv_file": str(output_file) if config["write_csv"] else None,
    }


def get_months(start_year, start_month):
    current_month = datetime.now(timezone.utc).date().replace(day=1)
    month = date(start_year, start_month, 1)
    months = []

    while month <= current_month:
        months.append((month.year, month.month))
        if month.month == 12:
            month = date(month.year + 1, 1, 1)
        else:
            month = date(month.year, month.month + 1, 1)
    return months


def process_month(year, month, config, backfill_start_date=None):
    _, last_day = calendar.monthrange(year, month)
    start = date(year, month, 1)
    if backfill_start_date:
        start = max(start, backfill_start_date)
    last_completed_date = datetime.now(timezone.utc).date() - timedelta(days=1)
    end = min(date(year, month, last_day), last_completed_date)
    if start > last_completed_date:
        return []

    rows = []
    token = generate_token(config)
    token_time = time.time()
    current = start

    while current <= end:
        if time.time() - token_time > 900:
            token = generate_token(config)
            token_time = time.time()

        try:
            daily_rows = download_subscriber_report(
                current,
                token,
                config["vendor_number"],
            )
            rows.extend(daily_rows)
            print(f"  {current}: {len(daily_rows)} rows")
        except requests.HTTPError as exc:
            if exc.response.status_code == 404:
                print(f"  {current}: not available")
            else:
                raise
        current += timedelta(days=1)

    return rows


def export_monthly_backfill(start_year, start_month, backfill_start_date=None):
    config = get_config()
    total_rows = 0

    for year, month in get_months(start_year, start_month):
        print(f"[{year}-{month:02d}] Downloading...")
        rows = process_month(
            year,
            month,
            config,
            backfill_start_date=backfill_start_date,
        )
        if not rows:
            print("  No data available")
            continue

        output_file = config["output_dir"] / (
            f"subscriber_report_{year}_{month:02d}.csv"
        )
        source_dates = [
            date.fromisoformat(row["source_report_date"])
            for row in rows
        ]
        write_outputs(
            rows,
            output_file,
            min(source_dates),
            max(source_dates),
            config,
        )
        total_rows += len(rows)

    print(f"Done. Total rows: {total_rows}")


def build_parser():
    parser = argparse.ArgumentParser(
        description="Apple App Store Subscriber Report exporter."
    )
    parser.add_argument(
        "mode",
        nargs="?",
        default="daily",
        choices=("daily", "monthly"),
    )
    parser.add_argument(
        "--date",
        type=parse_date,
        help="Daily modunda hedef rapor günü (YYYY-MM-DD).",
    )
    parser.add_argument(
        "--allow-fallback",
        action="store_true",
        help="Hedef rapor 404 ise önceki erişilebilir rapor gününe düş.",
    )
    parser.add_argument("--start-year", type=int, default=START_YEAR)
    parser.add_argument("--start-month", type=int, default=START_MONTH)
    parser.add_argument(
        "--start-date",
        type=parse_date,
        help="Monthly backfill için kesin başlangıç günü (YYYY-MM-DD).",
    )
    return parser


def main():
    args = build_parser().parse_args()
    try:
        if args.mode == "daily":
            export_daily(
                requested_date=args.date,
                allow_fallback=args.allow_fallback,
            )
        else:
            export_monthly_backfill(
                args.start_year,
                args.start_month,
                backfill_start_date=args.start_date,
            )
    except Exception as exc:
        print(f"ERROR: {type(exc).__name__}: {exc}", file=sys.stderr)
        raise


if __name__ == "__main__":
    main()
