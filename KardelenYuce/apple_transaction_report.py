"""
Apple App Store Transaction Report Generator

Sources:
1. App Store Connect API - Subscriber Reports (subscriberId, country, customerPrice, productId)
2. App Store Server API - Transaction details (transactionId, originalTransactionId)
3. App Store Server Notifications History - Bulk transaction ID discovery

Requirements:
    pip install PyJWT cryptography requests
"""

import jwt
import time
import json
import csv
import gzip
import base64
import requests
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path
from collections import defaultdict

# ============================================================
# CONFIGURATION
# ============================================================

CONNECT_ISSUER_ID = "203234da-b081-42db-88a4-de4b9d0fc6e1"
CONNECT_KEY_ID = "3JUWC66S52"
CONNECT_PRIVATE_KEY_PATH = "/Users/batuhancakir/Downloads/AuthKey_3JUWC66S52_app_store_connect_api_token.p8"

SERVER_API_KEY_ID = "W3Q4VCK3WR"
SERVER_API_ISSUER_ID = "203234da-b081-42db-88a4-de4b9d0fc6e1"
SERVER_API_BUNDLE_ID = "com.trgain.mikrogain"
SERVER_API_PRIVATE_KEY_PATH = "/Users/batuhancakir/Downloads/SubscriptionKey_W3Q4VCK3WR_inn-app_purchase_token.p8"
SERVER_API_ENVIRONMENT = "Production"

VENDOR_NUMBER = "89408638"
OUTPUT_FILE = "apple_transaction_report_april_2026.csv"
DAYS_BACK = 30


# ============================================================
# TOKEN GENERATION
# ============================================================

def generate_connect_token():
    private_key = Path(CONNECT_PRIVATE_KEY_PATH).read_text()
    now = int(time.time())
    payload = {"iss": CONNECT_ISSUER_ID, "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"}
    headers = {"alg": "ES256", "kid": CONNECT_KEY_ID, "typ": "JWT"}
    return jwt.encode(payload, private_key, algorithm="ES256", headers=headers)


def generate_server_api_token():
    private_key = Path(SERVER_API_PRIVATE_KEY_PATH).read_text()
    now = int(time.time())
    payload = {"iss": SERVER_API_ISSUER_ID, "iat": now, "exp": now + 3600,
               "aud": "appstoreconnect-v1", "bid": SERVER_API_BUNDLE_ID}
    headers = {"alg": "ES256", "kid": SERVER_API_KEY_ID, "typ": "JWT"}
    return jwt.encode(payload, private_key, algorithm="ES256", headers=headers)


# ============================================================
# APP STORE CONNECT API - Reports
# ============================================================

def download_subscriber_report(report_date, vendor_number):
    token = generate_connect_token()
    params = {
        "filter[reportType]": "SUBSCRIBER",
        "filter[reportSubType]": "DETAILED",
        "filter[frequency]": "DAILY",
        "filter[vendorNumber]": vendor_number,
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


def download_reports_for_range(start_date, end_date, vendor_number):
    all_rows = []
    current = start_date
    while current <= end_date:
        date_str = current.strftime("%Y-%m-%d")
        try:
            rows = download_subscriber_report(date_str, vendor_number)
            all_rows.extend(rows)
            print(f"    {date_str}: {len(rows)} rows")
        except requests.HTTPError as e:
            if e.response.status_code == 404:
                print(f"    {date_str}: -")
            else:
                print(f"    {date_str}: Error {e.response.status_code}")
        current += timedelta(days=1)
    return all_rows


# ============================================================
# APP STORE SERVER API - Transaction Details
# ============================================================

def get_server_api_base_url():
    if SERVER_API_ENVIRONMENT == "Sandbox":
        return "https://api.storekit-sandbox.itunes.apple.com"
    return "https://api.storekit.itunes.apple.com"


def get_transaction_history(original_transaction_id):
    token = generate_server_api_token()
    base_url = get_server_api_base_url()
    url = f"{base_url}/inApps/v2/history/{original_transaction_id}"
    headers = {"Authorization": f"Bearer {token}"}
    all_transactions = []
    revision = None

    while True:
        params = {"revision": revision} if revision else {}
        resp = requests.get(url, headers=headers, params=params)
        resp.raise_for_status()
        data = resp.json()

        for signed_tx in data.get("signedTransactions", []):
            tx = decode_jws_payload(signed_tx)
            all_transactions.append({
                "transactionId": str(tx.get("transactionId", "")),
                "originalTransactionId": str(tx.get("originalTransactionId", "")),
                "purchaseDate": format_timestamp(tx.get("purchaseDate")),
                "productId": tx.get("productId", ""),
                "storefront": tx.get("storefront", ""),
                "price": tx.get("price"),
                "currency": tx.get("currency", ""),
            })

        if not data.get("hasMore", False):
            break
        revision = data.get("revision")

    return all_transactions


def get_notification_history(start_date, end_date, max_pages=None):
    """Fetch bulk transaction IDs from notification history."""
    base_url = get_server_api_base_url()
    url = f"{base_url}/inApps/v1/notifications/history"
    body = {
        "startDate": int(start_date.timestamp() * 1000),
        "endDate": int(end_date.timestamp() * 1000),
    }

    all_original_tx_ids = set()
    pagination_token = None
    pages = 0
    token = generate_server_api_token()
    token_time = time.time()

    while True:
        # Refresh token every 45 minutes
        if time.time() - token_time > 2700:
            token = generate_server_api_token()
            token_time = time.time()

        headers = {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}
        if pagination_token:
            body["paginationToken"] = pagination_token
        resp = requests.post(url, headers=headers, json=body)
        resp.raise_for_status()
        data = resp.json()
        pages += 1

        for item in data.get("notificationHistory", []):
            signed_payload = item.get("signedPayload", "")
            if signed_payload:
                payload = decode_jws_payload(signed_payload)
                tx_info = payload.get("data", {}).get("signedTransactionInfo", "")
                if tx_info:
                    tx = decode_jws_payload(tx_info)
                    otx = tx.get("originalTransactionId")
                    if otx:
                        all_original_tx_ids.add(str(otx))

        if pages % 100 == 0:
            print(f"    Page {pages}: {len(all_original_tx_ids)} unique IDs so far...")

        if not data.get("hasMore", False):
            break
        if max_pages and pages >= max_pages:
            print(f"    Reached max pages limit ({max_pages})")
            break
        pagination_token = data.get("paginationToken")

    print(f"    Total pages: {pages}")
    return list(all_original_tx_ids)


# ============================================================
# HELPERS
# ============================================================

def decode_jws_payload(signed_token):
    parts = signed_token.split(".")
    if len(parts) != 3:
        return {}
    payload_b64 = parts[1]
    padding = 4 - len(payload_b64) % 4
    if padding != 4:
        payload_b64 += "=" * padding
    return json.loads(base64.urlsafe_b64decode(payload_b64))


def format_timestamp(ms_timestamp):
    if not ms_timestamp:
        return ""
    return datetime.fromtimestamp(ms_timestamp / 1000, tz=timezone.utc).strftime("%Y-%m-%d %H:%M:%S")


# ============================================================
# MERGE LOGIC
# ============================================================

def build_tx_index(all_server_transactions):
    """Index server transactions by (productId, date) for matching."""
    index = defaultdict(list)
    for tx in all_server_transactions:
        product_id = tx["productId"]
        purchase_date = tx["purchaseDate"][:10]  # YYYY-MM-DD
        index[(product_id, purchase_date)].append(tx)
    return index


def enrich_subscriber_rows(subscriber_rows, tx_index):
    """Match subscriber rows with server transactions using productId + date."""
    enriched = []
    matched = 0

    for row in subscriber_rows:
        event_date = row.get("Event Date", "")
        product_id = row.get("Subscription Apple ID", row.get("Apple Identifier", ""))
        subscriber_id = row.get("Subscriber ID", "")
        country = row.get("Country", "")
        customer_price = row.get("Customer Price", "")
        customer_currency = row.get("Customer Currency", "")
        subscription_name = row.get("Subscription Name", "")
        device = row.get("Device", "")
        proceeds = row.get("Developer Proceeds", "")
        proceeds_currency = row.get("Proceeds Currency", "")

        # Try to match with server transaction
        tx_match = None
        key = (product_id, event_date)
        if key in tx_index and tx_index[key]:
            tx_match = tx_index[key].pop(0)
            matched += 1

        enriched.append({
            "transactionId": tx_match["transactionId"] if tx_match else "",
            "originalTransactionId": tx_match["originalTransactionId"] if tx_match else "",
            "purchaseDate": event_date,
            "productId": product_id,
            "subscriptionName": subscription_name,
            "country": country,
            "customerPrice": customer_price,
            "customerCurrency": customer_currency,
            "developerProceeds": proceeds,
            "proceedsCurrency": proceeds_currency,
            "subscriberId": subscriber_id,
            "device": device,
        })

    return enriched, matched


# ============================================================
# REPORT OUTPUT
# ============================================================

FIELDNAMES = [
    "transactionId",
    "originalTransactionId",
    "purchaseDate",
    "productId",
    "subscriptionName",
    "country",
    "customerPrice",
    "customerCurrency",
    "developerProceeds",
    "proceedsCurrency",
    "subscriberId",
    "device",
]


def write_csv(rows, output_file):
    if not rows:
        print("No data to write.")
        return
    with open(output_file, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=FIELDNAMES)
        writer.writeheader()
        for row in rows:
            writer.writerow({k: row.get(k, "") for k in FIELDNAMES})
    print(f"  Saved: {output_file} ({len(rows)} rows)")


# ============================================================
# MAIN
# ============================================================

def main():
    print("=" * 60)
    print("Apple App Store Transaction Report Generator")
    print("=" * 60)

    # Nisan 2026 - 1 Nisan'dan dünkü tarihe kadar
    start_date = datetime(2026, 4, 1, tzinfo=timezone.utc)
    end_date = datetime.now(tz=timezone.utc) - timedelta(days=1)

    print(f"\nDate range: {start_date.strftime('%Y-%m-%d')} to {end_date.strftime('%Y-%m-%d')}")

    # --- Step 1: Download Subscriber Reports ---
    print("\n[1/3] Downloading Subscriber Reports...")
    subscriber_rows = download_reports_for_range(start_date, end_date, VENDOR_NUMBER)
    print(f"\n  Total: {len(subscriber_rows)} subscriber rows")

    if not subscriber_rows:
        print("  No subscriber data found.")
        return

    # --- Step 2: Get bulk transaction IDs ---
    print("\n[2/3] Fetching transaction IDs from Server API...")
    all_server_txs = []

    # Method 1: Try notification history (bulk)
    print("  Trying notification history...")
    try:
        original_tx_ids = get_notification_history(start_date, end_date)
        print(f"  Found {len(original_tx_ids)} unique original transaction IDs")

        # Fetch transaction details for each
        for i, otx_id in enumerate(original_tx_ids):
            try:
                txs = get_transaction_history(otx_id)
                all_server_txs.extend(txs)
                if (i + 1) % 50 == 0:
                    print(f"    Processed {i + 1}/{len(original_tx_ids)} ({len(all_server_txs)} transactions)")
            except Exception as e:
                print(f"    {otx_id}: Error - {e}")

        print(f"  Total server transactions: {len(all_server_txs)}")

    except requests.HTTPError as e:
        if e.response.status_code == 404:
            print("  Notification history not available (notification URL not configured)")
            print("  To enable: App Store Connect > App > General > App Store Server Notifications")
            print("  Set a Production/Sandbox URL, then notification history will work.")
            print()
            print("  Trying alternative: fetching sample transactions...")

            # Method 2: Get unique Subscription Apple IDs and try known patterns
            unique_products = set()
            for row in subscriber_rows:
                pid = row.get("Subscription Apple ID", "")
                if pid:
                    unique_products.add(pid)
            print(f"  Found {len(unique_products)} unique subscription products")

        else:
            print(f"  Error: {e}")

    # --- Step 3: Merge and output ---
    print("\n[3/3] Generating report...")

    if all_server_txs:
        tx_index = build_tx_index(all_server_txs)
        enriched, matched = enrich_subscriber_rows(subscriber_rows, tx_index)
        print(f"  Matched {matched}/{len(subscriber_rows)} rows with transaction IDs")
        write_csv(enriched, OUTPUT_FILE)
    else:
        # Output subscriber data without transaction IDs
        enriched, _ = enrich_subscriber_rows(subscriber_rows, {})
        write_csv(enriched, OUTPUT_FILE)
        print(f"\n  Note: transactionId/originalTransactionId columns are empty.")
        print("  To fill them, set up App Store Server Notifications URL:")
        print("  App Store Connect > Apps > GAİN > General > App Store Server Notifications")

    print("\nDone!")


if __name__ == "__main__":
    main()
