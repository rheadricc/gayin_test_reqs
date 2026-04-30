import io
import zipfile
import pandas as pd
from datetime import datetime, timezone, timedelta
from urllib.parse import quote
from pathlib import Path

from google.oauth2 import service_account
from google.auth.transport.requests import AuthorizedSession


SERVICE_ACCOUNT_JSON = "/Users/batuhancakir/Downloads/bc_google_play_console_keys.json"
BUCKET_NAME = "pubsite_prod_9095964761589449343"
SCOPES = ["https://www.googleapis.com/auth/devstorage.read_only"]

BASE_DIR = Path(__file__).resolve().parent
OUTPUT_FILE = BASE_DIR / "google_play_sales_t_minus_1.csv"


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


def main():
    session = get_session()

    today_utc = datetime.now(timezone.utc).date()
    target_date = today_utc - timedelta(days=1)

    ym = target_date.strftime("%Y%m")
    object_name = f"sales/salesreport_{ym}.zip"

    print(f"Target date: {target_date}")
    print(f"Object: {object_name}")
    print(f"Output file: {OUTPUT_FILE}")

    zip_bytes = download_object(session, object_name)
    df = parse_zip_csv(zip_bytes, object_name)

    df["transaction_date_parsed"] = pd.to_datetime(
        df["Order Charged Date"],
        errors="coerce"
    ).dt.date

    daily_df = df[df["transaction_date_parsed"] == target_date].copy()

    print(f"Total rows in monthly file: {len(df)}")
    print(f"T-1 rows: {len(daily_df)}")

    daily_df.to_csv(OUTPUT_FILE, index=False, encoding="utf-8-sig")

    print(daily_df.head())
    print(f"Saved: {OUTPUT_FILE}")


if __name__ == "__main__":
    main()