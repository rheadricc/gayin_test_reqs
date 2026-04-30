"""
Apple App Store - Monthly Subscriber Reports
Downloads subscriber reports month by month from November 2024.
Each month saved as a separate CSV file.

Requirements:
    pip install PyJWT cryptography requests
"""

import jwt
import time
import csv
import gzip
import requests
from datetime import datetime, timedelta, timezone
from pathlib import Path
import calendar
import os

# ============================================================
# CONFIGURATION
# ============================================================

CONNECT_ISSUER_ID = "203234da-b081-42db-88a4-de4b9d0fc6e1"
CONNECT_KEY_ID = "3JUWC66S52"
CONNECT_PRIVATE_KEY_PATH = "/Users/batuhancakir/Downloads/AuthKey_3JUWC66S52_app_store_connect_api_token.p8"

VENDOR_NUMBER = "89408638"
OUTPUT_DIR = "/Users/batuhancakir/GAIN_API_QUERY/apple_api_files/applereports"

# Date range
START_YEAR = 2026
START_MONTH = 4
# End: current month (exclusive — reports have 1-day delay)


# ============================================================
# TOKEN & API
# ============================================================

def generate_token():
    private_key = Path(CONNECT_PRIVATE_KEY_PATH).read_text()
    now = int(time.time())
    payload = {"iss": CONNECT_ISSUER_ID, "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"}
    headers = {"alg": "ES256", "kid": CONNECT_KEY_ID, "typ": "JWT"}
    return jwt.encode(payload, private_key, algorithm="ES256", headers=headers)


def download_subscriber_report(report_date, token):
    params = {
        "filter[reportType]": "SUBSCRIBER",
        "filter[reportSubType]": "DETAILED",
        "filter[frequency]": "DAILY",
        "filter[vendorNumber]": VENDOR_NUMBER,
        "filter[reportDate]": report_date,
        "filter[version]": "1_3",
    }
    resp = requests.get(
        "https://api.appstoreconnect.apple.com/v1/salesReports",
        headers={"Authorization": f"Bearer {token}"},
        params=params,
    )
    resp.raise_for_status()
    content = gzip.decompress(resp.content).decode("utf-8")
    return list(csv.DictReader(content.splitlines(), delimiter="\t"))


def get_months(start_year, start_month):
    """Generate list of (year, month) from start to current month."""
    now = datetime.now(tz=timezone.utc)
    current_year = now.year
    current_month = now.month

    months = []
    y, m = start_year, start_month
    while (y, m) <= (current_year, current_month):
        months.append((y, m))
        m += 1
        if m > 12:
            m = 1
            y += 1
    return months


def process_month(year, month):
    """Download all daily subscriber reports for a given month."""
    _, last_day = calendar.monthrange(year, month)
    start = datetime(year, month, 1, tzinfo=timezone.utc)

    # Don't go beyond yesterday
    yesterday = datetime.now(tz=timezone.utc) - timedelta(days=1)
    end = min(datetime(year, month, last_day, tzinfo=timezone.utc), yesterday)

    if start > yesterday:
        return []

    all_rows = []
    token = generate_token()
    token_time = time.time()
    current = start

    while current <= end:
        # Refresh token every 15 minutes
        if time.time() - token_time > 900:
            token = generate_token()
            token_time = time.time()

        date_str = current.strftime("%Y-%m-%d")
        try:
            rows = download_subscriber_report(date_str, token)
            all_rows.extend(rows)
        except requests.HTTPError as e:
            if e.response.status_code == 404:
                pass  # No report for this day
            else:
                print(f"      {date_str}: Error {e.response.status_code}")
        current += timedelta(days=1)

    return all_rows


def write_month_csv(rows, year, month, output_dir):
    """Write a month's data to CSV."""
    if not rows:
        return 0

    filename = f"subscriber_report_{year}_{month:02d}.csv"
    filepath = os.path.join(output_dir, filename)

    fieldnames = [
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

    with open(filepath, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)

    return len(rows)


def main():
    print("=" * 60)
    print("Apple App Store - Monthly Subscriber Reports")
    print("=" * 60)

    os.makedirs(OUTPUT_DIR, exist_ok=True)
    months = get_months(START_YEAR, START_MONTH)
    print(f"\nMonths to process: {len(months)}")
    print(f"Output directory: {OUTPUT_DIR}\n")

    total_rows = 0

    for year, month in months:
        month_name = f"{year}-{month:02d}"
        print(f"[{month_name}] Downloading...", end=" ", flush=True)

        rows = process_month(year, month)

        if rows:
            count = write_month_csv(rows, year, month, OUTPUT_DIR)
            print(f"{count} rows -> subscriber_report_{year}_{month:02d}.csv")
            total_rows += count
        else:
            print("No data available")

    print(f"\nDone! Total: {total_rows} rows across {len(months)} months")
    print(f"Files saved in: {OUTPUT_DIR}")


if __name__ == "__main__":
    main()
