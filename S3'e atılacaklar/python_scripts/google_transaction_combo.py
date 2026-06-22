import argparse
import io
import json
import os
import re
import sys
import zipfile
from datetime import date, datetime, timedelta, timezone
from decimal import Decimal, InvalidOperation
from pathlib import Path
from urllib.parse import quote
from uuid import uuid4

import pandas as pd
from google.api_core.exceptions import NotFound
from google.auth.transport.requests import AuthorizedSession
from google.cloud import bigquery
from google.oauth2 import service_account

DEFAULT_SERVICE_ACCOUNT_JSON = (
    "/Users/batuhancakir/Downloads/bc_google_play_console_keys.json"
)
DEFAULT_BUCKET_NAME = "pubsite_prod_9095964761589449343"
SCOPES = ["https://www.googleapis.com/auth/devstorage.read_only"]

BASE_DIR = Path(__file__).resolve().parent
DEFAULT_OUTPUT_DIR = BASE_DIR / "google_play_outputs"

GOOGLE_BQ_SCHEMA = [
    bigquery.SchemaField("order_number", "STRING"),
    bigquery.SchemaField("order_charged_date", "DATE"),
    bigquery.SchemaField("order_charged_timestamp", "TIMESTAMP"),
    bigquery.SchemaField("financial_status", "STRING"),
    bigquery.SchemaField("device_model", "STRING"),
    bigquery.SchemaField("product_title", "STRING"),
    bigquery.SchemaField("package_id", "STRING"),
    bigquery.SchemaField("product_type", "STRING"),
    bigquery.SchemaField("sku_id", "STRING"),
    bigquery.SchemaField("currency_of_sale", "STRING"),
    bigquery.SchemaField("item_price", "NUMERIC"),
    bigquery.SchemaField("taxes_collected", "NUMERIC"),
    bigquery.SchemaField("charged_amount", "NUMERIC"),
    bigquery.SchemaField("city_of_buyer", "STRING"),
    bigquery.SchemaField("state_of_buyer", "STRING"),
    bigquery.SchemaField("postal_code_of_buyer", "STRING"),
    bigquery.SchemaField("country_of_buyer", "STRING"),
    bigquery.SchemaField("base_plan_or_purchase_option_id", "STRING"),
    bigquery.SchemaField("offer_id", "STRING"),
    bigquery.SchemaField("group_id", "STRING"),
    bigquery.SchemaField("first_usd_1m_eligible", "STRING"),
    bigquery.SchemaField("promotion_id", "STRING"),
    bigquery.SchemaField("coupon_value", "NUMERIC"),
    bigquery.SchemaField("discount_rate", "NUMERIC"),
    bigquery.SchemaField("featured_product_id", "STRING"),
    bigquery.SchemaField("price_experiment_id", "STRING"),
    bigquery.SchemaField("sales_channel", "STRING"),
    bigquery.SchemaField("source_zip", "STRING"),
    bigquery.SchemaField("source_csv", "STRING"),
    bigquery.SchemaField("report_target_date", "DATE"),
    bigquery.SchemaField("export_loaded_at_utc", "TIMESTAMP"),
]

GOOGLE_COLUMN_MAP = {
    "Order Number": "order_number",
    "Order Charged Date": "order_charged_date",
    "Order Charged Timestamp": "order_charged_timestamp",
    "Financial Status": "financial_status",
    "Device Model": "device_model",
    "Product Title": "product_title",
    "Package ID": "package_id",
    "Product Type": "product_type",
    "SKU ID": "sku_id",
    "Currency of Sale": "currency_of_sale",
    "Item Price": "item_price",
    "Taxes Collected": "taxes_collected",
    "Charged Amount": "charged_amount",
    "City of Buyer": "city_of_buyer",
    "State of Buyer": "state_of_buyer",
    "Postal Code of Buyer": "postal_code_of_buyer",
    "Country of Buyer": "country_of_buyer",
    "Base Plan or Purchase Option ID": "base_plan_or_purchase_option_id",
    "Offer ID": "offer_id",
    "Group ID": "group_id",
    "First USD 1M Eligible": "first_usd_1m_eligible",
    "Promotion ID": "promotion_id",
    "Coupon Value": "coupon_value",
    "Discount Rate": "discount_rate",
    "Featured Product ID": "featured_product_id",
    "Featured Products ID": "featured_product_id",
    "Price Experiment ID": "price_experiment_id",
    "Sales Channel": "sales_channel",
    "source_zip": "source_zip",
    "source_csv": "source_csv",
    "report_target_date": "report_target_date",
    "export_loaded_at_utc": "export_loaded_at_utc",
}


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
        "service_account_json": os.getenv(
            "GOOGLE_PLAY_SERVICE_ACCOUNT_JSON",
            DEFAULT_SERVICE_ACCOUNT_JSON,
        ),
        "bucket_name": os.getenv(
            "GOOGLE_PLAY_BUCKET_NAME",
            DEFAULT_BUCKET_NAME,
        ),
        "output_dir": Path(
            os.getenv("GOOGLE_PLAY_OUTPUT_DIR", str(DEFAULT_OUTPUT_DIR))
        ),
        "write_csv": write_csv,
        "bq_enabled": bq_enabled,
        "bq_project_id": os.getenv("BQ_PROJECT_ID", "microgain-9f959").strip(),
        "bq_dataset": os.getenv("BQ_DATASET", "bc_t").strip(),
        "bq_table": os.getenv(
            "BQ_TABLE",
            "googleplay_transactions_raw",
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


def load_service_account_credentials(value, scopes):
    raw_value = value.strip()
    if raw_value.startswith("{"):
        return service_account.Credentials.from_service_account_info(
            json.loads(raw_value),
            scopes=scopes,
        )

    credentials_path = Path(raw_value)
    if not credentials_path.is_file():
        raise FileNotFoundError(
            f"Service-account JSON bulunamadı: {credentials_path}"
        )
    return service_account.Credentials.from_service_account_file(
        credentials_path,
        scopes=scopes,
    )


def parse_date(value):
    try:
        return datetime.strptime(value, "%Y-%m-%d").date()
    except ValueError as exc:
        raise argparse.ArgumentTypeError(
            f"Geçersiz tarih: {value}. Beklenen format YYYY-MM-DD."
        ) from exc


def get_session(service_account_json):
    creds = load_service_account_credentials(
        service_account_json,
        SCOPES,
    )
    return AuthorizedSession(creds)


def download_object(session, bucket_name, object_name):
    encoded_object_name = quote(object_name, safe="")
    url = (
        "https://storage.googleapis.com/download/storage/v1/b/"
        f"{bucket_name}/o/{encoded_object_name}?alt=media"
    )

    response = session.get(url, timeout=120)
    print(f"DOWNLOAD {object_name} -> {response.status_code}")
    if response.status_code != 200:
        print(response.text[:1000])
        response.raise_for_status()

    return response.content


def parse_zip_csv(zip_bytes, source_file):
    with zipfile.ZipFile(io.BytesIO(zip_bytes)) as archive:
        csv_files = [
            name for name in archive.namelist() if name.lower().endswith(".csv")
        ]
        if not csv_files:
            raise RuntimeError(f"ZIP içinde CSV bulunamadı: {source_file}")

        frames = []
        for csv_name in csv_files:
            with archive.open(csv_name) as csv_file:
                frame = pd.read_csv(csv_file)

            frame["source_zip"] = source_file
            frame["source_csv"] = csv_name
            frames.append(frame)

    return pd.concat(frames, ignore_index=True)


def normalize_report(frame):
    required_columns = {"Order Charged Date", "Order Number", "Financial Status"}
    missing_columns = sorted(required_columns - set(frame.columns))
    if missing_columns:
        raise RuntimeError(
            "Google Play raporunda beklenen kolonlar eksik: "
            + ", ".join(missing_columns)
        )

    normalized = frame.copy()
    normalized["order_charged_date"] = pd.to_datetime(
        normalized["Order Charged Date"],
        errors="coerce",
    ).dt.date
    return normalized


def get_requested_range(mode, requested_date=None):
    today_utc = datetime.now(timezone.utc).date()
    last_completed_date = today_utc - timedelta(days=1)

    if mode == "daily":
        target_date = requested_date or last_completed_date
        return target_date, target_date

    if requested_date:
        raise ValueError("--date yalnızca daily modunda kullanılabilir.")

    if mode == "manual":
        return today_utc.replace(day=1), last_completed_date

    if mode == "monthly":
        first_day_this_month = today_utc.replace(day=1)
        last_day_previous_month = first_day_this_month - timedelta(days=1)
        return last_day_previous_month.replace(day=1), last_day_previous_month

    raise ValueError("Mode daily, monthly veya manual olmalı.")


def get_month_starts(start_date, end_date):
    current = start_date.replace(day=1)
    final = end_date.replace(day=1)
    months = []

    while current <= final:
        months.append(current)
        if current.month == 12:
            current = date(current.year + 1, 1, 1)
        else:
            current = date(current.year, current.month + 1, 1)

    return months


def get_month_range(month_start, overall_start, overall_end):
    if month_start.month == 12:
        next_month = date(month_start.year + 1, 1, 1)
    else:
        next_month = date(month_start.year, month_start.month + 1, 1)
    month_end = next_month - timedelta(days=1)
    return max(month_start, overall_start), min(month_end, overall_end)


def download_range(session, bucket_name, start_date, end_date):
    frames = []
    for month_start in get_month_starts(start_date, end_date):
        object_name = f"sales/salesreport_{month_start:%Y%m}.zip"
        zip_bytes = download_object(session, bucket_name, object_name)
        frames.append(normalize_report(parse_zip_csv(zip_bytes, object_name)))

    return pd.concat(frames, ignore_index=True)


def choose_daily_date(frame, requested_date, allow_fallback):
    available_dates = frame["order_charged_date"].dropna()
    available_dates = available_dates[available_dates <= requested_date]
    if available_dates.empty:
        raise RuntimeError(
            f"{requested_date} veya öncesi için Google Play satırı bulunamadı."
        )

    latest_available = max(available_dates)
    if latest_available == requested_date:
        return requested_date

    if not allow_fallback:
        raise RuntimeError(
            f"Google Play {requested_date} raporu henüz tamamlanmamış görünüyor. "
            f"Son erişilebilir işlem günü: {latest_available}."
        )

    print(
        f"Requested date {requested_date} is not available; "
        f"using latest completed date {latest_available}."
    )
    return latest_available


def clean_string(value):
    if value is None or pd.isna(value):
        return None
    return str(value).strip()


def clean_decimal(value):
    text = clean_string(value)
    if not text:
        return None
    try:
        return str(Decimal(text.replace(",", "")))
    except InvalidOperation:
        raise ValueError(f"Sayısal Google Play değeri parse edilemedi: {value}")


def clean_timestamp(value):
    if value is None or pd.isna(value):
        return None
    text = str(value).strip()
    if not text:
        return None
    if re.fullmatch(r"\d+(\.0+)?", text):
        return datetime.fromtimestamp(float(text), tz=timezone.utc).isoformat()
    return pd.to_datetime(text, utc=True).isoformat()


def prepare_bigquery_rows(frame):
    bq_frame = frame.rename(columns=GOOGLE_COLUMN_MAP)
    duplicate_columns = bq_frame.columns[bq_frame.columns.duplicated()].tolist()
    if duplicate_columns:
        bq_frame = bq_frame.loc[:, ~bq_frame.columns.duplicated(keep="last")]

    schema_names = [field.name for field in GOOGLE_BQ_SCHEMA]
    for column in schema_names:
        if column not in bq_frame.columns:
            bq_frame[column] = None
    bq_frame = bq_frame[schema_names]

    decimal_columns = {
        "item_price",
        "taxes_collected",
        "charged_amount",
        "coupon_value",
        "discount_rate",
    }
    date_columns = {"order_charged_date", "report_target_date"}
    timestamp_columns = {"order_charged_timestamp", "export_loaded_at_utc"}

    rows = []
    for raw_row in bq_frame.to_dict(orient="records"):
        clean_row = {}
        for column, value in raw_row.items():
            if column in decimal_columns:
                clean_row[column] = clean_decimal(value)
            elif column in date_columns:
                text = clean_string(value)
                clean_row[column] = date.fromisoformat(text).isoformat() if text else None
            elif column in timestamp_columns:
                clean_row[column] = clean_timestamp(value)
            else:
                clean_row[column] = clean_string(value)
        rows.append(clean_row)
    return rows


def get_bigquery_client(config):
    credentials_value = (
        config["bq_service_account_json"]
        or os.getenv("GOOGLE_APPLICATION_CREDENTIALS", "").strip()
    )
    if credentials_value:
        credentials = load_service_account_credentials(
            credentials_value,
            ["https://www.googleapis.com/auth/cloud-platform"],
        )
        return bigquery.Client(
            project=config["bq_project_id"],
            credentials=credentials,
        )
    return bigquery.Client(project=config["bq_project_id"])


def ensure_bigquery_table(client, table_id):
    try:
        client.get_table(table_id)
    except NotFound:
        table = bigquery.Table(table_id, schema=GOOGLE_BQ_SCHEMA)
        table.time_partitioning = bigquery.TimePartitioning(
            type_=bigquery.TimePartitioningType.DAY,
            field="order_charged_date",
        )
        client.create_table(table)
        print(f"[BQ] Table created: {table_id}")


def load_to_bigquery(frame, start_date, end_date, config):
    rows = prepare_bigquery_rows(frame)
    if not rows:
        raise RuntimeError("BigQuery'ye yüklenecek Google Play satırı yok.")

    table_id = (
        f"{config['bq_project_id']}."
        f"{config['bq_dataset']}."
        f"{config['bq_table']}"
    )
    staging_table_id = f"{table_id}__staging_{uuid4().hex}"
    client = get_bigquery_client(config)
    ensure_bigquery_table(client, table_id)

    staging_config = bigquery.LoadJobConfig(
        schema=GOOGLE_BQ_SCHEMA,
        write_disposition=bigquery.WriteDisposition.WRITE_TRUNCATE,
    )
    client.load_table_from_json(
        rows,
        staging_table_id,
        job_config=staging_config,
    ).result()

    try:
        sql = f"""
        BEGIN TRANSACTION;
        DELETE FROM `{table_id}`
        WHERE order_charged_date BETWEEN @start_date AND @end_date;
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

    print(f"[BQ] Loaded rows: {len(rows)} -> {table_id}")


def export_sales(mode, requested_date=None, allow_fallback=False):
    config = get_config()
    if config["write_csv"]:
        config["output_dir"].mkdir(parents=True, exist_ok=True)

    start_date, end_date = get_requested_range(mode, requested_date)
    print(f"Mode: {mode}")
    print(f"Requested date range: {start_date} to {end_date}")

    session = get_session(config["service_account_json"])
    frame = download_range(
        session,
        config["bucket_name"],
        start_date,
        end_date,
    )

    if mode == "daily":
        selected_date = choose_daily_date(frame, end_date, allow_fallback)
        start_date = selected_date
        end_date = selected_date

    filtered = frame[
        (frame["order_charged_date"] >= start_date)
        & (frame["order_charged_date"] <= end_date)
    ].copy()

    if filtered.empty:
        raise RuntimeError(
            f"{start_date} - {end_date} aralığı için Google Play satırı yok."
        )

    filtered["report_target_date"] = end_date.isoformat()
    filtered["export_loaded_at_utc"] = datetime.now(timezone.utc).isoformat()

    print(f"Total rows in downloaded report(s): {len(frame)}")
    print(f"Exported rows: {len(filtered)}")
    print(f"Financial statuses: {filtered['Financial Status'].value_counts().to_dict()}")

    output_file = None
    if config["write_csv"]:
        output_file = config["output_dir"] / (
            f"google_play_sales_{mode}_"
            f"{start_date:%Y%m%d}_to_{end_date:%Y%m%d}.csv"
        )
        filtered.to_csv(output_file, index=False, encoding="utf-8-sig")
        print(f"[CSV] Saved: {output_file}")
    else:
        print("[CSV] WRITE_CSV=0 veya Airflow ortamı; CSV yazılmadı.")

    if config["bq_enabled"]:
        load_to_bigquery(filtered, start_date, end_date, config)
    else:
        print("[BQ] Lokal CSV modu; BigQuery yüklemesi atlandı.")

    return {
        "platform": "Google Play",
        "target_date": end_date.isoformat(),
        "row_count": len(filtered),
        "table_id": (
            f"{config['bq_project_id']}."
            f"{config['bq_dataset']}."
            f"{config['bq_table']}"
        ),
        "csv_file": str(output_file) if output_file else None,
    }


def export_backfill(start_date, end_date):
    if start_date > end_date:
        raise ValueError("Backfill başlangıç tarihi bitiş tarihinden büyük olamaz.")

    print(f"Backfill range: {start_date} to {end_date}")
    total_rows = 0
    for month_start in get_month_starts(start_date, end_date):
        chunk_start, chunk_end = get_month_range(
            month_start,
            start_date,
            end_date,
        )
        print(f"\n[BACKFILL] {chunk_start} to {chunk_end}")
        total_rows += export_date_range(chunk_start, chunk_end)

    print(f"[BACKFILL] Completed. Total loaded rows: {total_rows}")


def export_date_range(start_date, end_date):
    config = get_config()
    session = get_session(config["service_account_json"])
    frame = download_range(
        session,
        config["bucket_name"],
        start_date,
        end_date,
    )
    filtered = frame[
        (frame["order_charged_date"] >= start_date)
        & (frame["order_charged_date"] <= end_date)
    ].copy()
    if filtered.empty:
        raise RuntimeError(
            f"{start_date} - {end_date} aralığı için Google Play satırı yok."
        )

    filtered["report_target_date"] = end_date.isoformat()
    filtered["export_loaded_at_utc"] = datetime.now(timezone.utc).isoformat()
    print(f"[BACKFILL] Rows: {len(filtered)}")

    if config["write_csv"]:
        config["output_dir"].mkdir(parents=True, exist_ok=True)
        output_file = config["output_dir"] / (
            f"google_play_sales_backfill_"
            f"{start_date:%Y%m%d}_to_{end_date:%Y%m%d}.csv"
        )
        filtered.to_csv(output_file, index=False, encoding="utf-8-sig")
        print(f"[CSV] Saved: {output_file}")
    else:
        print("[CSV] WRITE_CSV=0; CSV yazılmadı.")

    if config["bq_enabled"]:
        load_to_bigquery(filtered, start_date, end_date, config)
    else:
        print("[BQ] Lokal CSV modu; BigQuery yüklemesi atlandı.")
    return len(filtered)


def build_parser():
    parser = argparse.ArgumentParser(
        description="Google Play estimated sales report exporter."
    )
    parser.add_argument(
        "mode",
        nargs="?",
        default="daily",
        choices=("daily", "monthly", "manual", "backfill"),
    )
    parser.add_argument(
        "--date",
        type=parse_date,
        help="Daily modunda hedef rapor günü (YYYY-MM-DD).",
    )
    parser.add_argument(
        "--allow-fallback",
        action="store_true",
        help="Hedef gün yoksa önceki erişilebilir işlem gününe düş.",
    )
    parser.add_argument(
        "--start-date",
        type=parse_date,
        help="Backfill başlangıç günü (YYYY-MM-DD).",
    )
    parser.add_argument(
        "--end-date",
        type=parse_date,
        help="Backfill bitiş günü (YYYY-MM-DD); varsayılan T-1.",
    )
    return parser


def main():
    args = build_parser().parse_args()
    try:
        if args.mode == "backfill":
            if not args.start_date:
                raise ValueError("backfill modu için --start-date zorunlu.")
            end_date = args.end_date or (
                datetime.now(timezone.utc).date() - timedelta(days=1)
            )
            export_backfill(args.start_date, end_date)
        else:
            export_sales(
                args.mode,
                requested_date=args.date,
                allow_fallback=args.allow_fallback,
            )
    except Exception as exc:
        print(f"ERROR: {type(exc).__name__}: {exc}", file=sys.stderr)
        raise


if __name__ == "__main__":
    main()
