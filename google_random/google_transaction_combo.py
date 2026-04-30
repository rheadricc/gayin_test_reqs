import io
import sys
import zipfile
import pandas as pd
from pathlib import Path
from datetime import datetime, timezone, timedelta
from urllib.parse import quote
from google.oauth2 import service_account
from google.auth.transport.requests import AuthorizedSession


SERVICE_ACCOUNT_JSON = "/Users/batuhancakir/Downloads/bc_google_play_console_keys.json"
BUCKET_NAME = "pubsite_prod_9095964761589449343"
SCOPES = ["https://www.googleapis.com/auth/devstorage.read_only"]

BASE_DIR = Path(__file__).resolve().parent
OUTPUT_DIR = BASE_DIR / "google_play_outputs"
OUTPUT_DIR.mkdir(exist_ok=True)


def get_session():
    creds = service_account.Credentials.from_service_account_file(
        SERVICE_ACCOUNT_JSON,
        scopes=SCOPES,
    )
    return AuthorizedSession(creds)


def download_object(session, object_name):
    encoded_object_name = quote(object_name, safe="")
    url = f"https://storage.googleapis.com/download/storage/v1/b/{BUCKET_NAME}/o/{encoded_object_name}?alt=media"

    resp = session.get(url)
    print(f"DOWNLOAD {object_name} -> {resp.status_code}")

    if resp.status_code != 200:
        print(resp.text[:1000])
        resp.raise_for_status()

    return resp.content


def parse_zip_csv(zip_bytes, source_file):
    with zipfile.ZipFile(io.BytesIO(zip_bytes)) as z:
        csv_files = [name for name in z.namelist() if name.endswith(".csv")]
        if not csv_files:
            raise Exception(f"No CSV found in {source_file}")

        dfs = []
        for csv_name in csv_files:
            with z.open(csv_name) as f:
                df = pd.read_csv(f)

            df["source_zip"] = source_file
            df["source_csv"] = csv_name
            dfs.append(df)

        return pd.concat(dfs, ignore_index=True)


def get_date_range(mode):
    today = datetime.now(timezone.utc).date()
    yesterday = today - timedelta(days=1)

    if mode == "daily":
        return yesterday, yesterday

    if mode == "manual":
        return today.replace(day=1), yesterday

    if mode == "monthly":
        first_day_this_month = today.replace(day=1)
        last_day_prev_month = first_day_this_month - timedelta(days=1)
        first_day_prev_month = last_day_prev_month.replace(day=1)
        return first_day_prev_month, last_day_prev_month

    raise ValueError("Mode must be one of: daily, monthly, manual")


def export_sales(mode):
    start_date, end_date = get_date_range(mode)

    # Aralık aynı ay içindeyse tek monthly salesreport dosyası yeterli.
    ym = start_date.strftime("%Y%m")
    object_name = f"sales/salesreport_{ym}.zip"

    output_file = OUTPUT_DIR / (
        f"google_play_sales_{mode}_{start_date.strftime('%Y%m%d')}_to_{end_date.strftime('%Y%m%d')}.csv"
    )

    print(f"Mode: {mode}")
    print(f"Date range: {start_date} to {end_date}")
    print(f"Object: {object_name}")
    print(f"Output file: {output_file}")

    session = get_session()
    zip_bytes = download_object(session, object_name)
    df = parse_zip_csv(zip_bytes, object_name)

    df["order_charged_date_parsed"] = pd.to_datetime(
        df["Order Charged Date"],
        errors="coerce"
    ).dt.date

    filtered_df = df[
        (df["order_charged_date_parsed"] >= start_date)
        & (df["order_charged_date_parsed"] <= end_date)
    ].copy()

    filtered_df.to_csv(output_file, index=False, encoding="utf-8-sig")

    print(f"Total rows in monthly file: {len(df)}")
    print(f"Filtered rows: {len(filtered_df)}")
    print(f"Saved: {output_file}")


if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else "daily"
    export_sales(mode)