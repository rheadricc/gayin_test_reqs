import base64
import csv
import json
import os
import time
from pathlib import Path
from typing import List, Dict

import jwt
import requests
from cryptography.hazmat.primitives import serialization


# =========================
# CONFIG
# =========================

ISSUER_ID = "203234da-b081-42db-88a4-de4b9d0fc6e1"
KEY_ID = "W3Q4VCK3WR"
BUNDLE_ID = "com.trgain.mikrogain"

PRIVATE_KEY_PATH = os.getenv(
    "APPLE_SERVER_API_PRIVATE_KEY_PATH",
    "/Users/batuhancakir/Downloads/"
    "SubscriptionKey_W3Q4VCK3WR_inn-app_purchase_token.p8",
)

CSV_FILE = "apple_ids.csv"

USE_SANDBOX = False
TARGET_YEAR = 2026
TARGET_MONTH = 4
REQUEST_TIMEOUT = 20
MAX_TEST_IDS = 0  # 0 = hepsini işle, 5 = ilk 5 ID gibi


# =========================
# KEY VALIDATION
# =========================

def load_private_key():
    private_key_path = Path(PRIVATE_KEY_PATH)
    if not private_key_path.is_file():
        raise FileNotFoundError(
            "Apple Server API private key bulunamadı: "
            f"{private_key_path}. APPLE_SERVER_API_PRIVATE_KEY_PATH ayarlanmalı."
        )
    return private_key_path.read_text()


def validate_private_key():
    try:
        serialization.load_pem_private_key(
            load_private_key().encode("utf-8"),
            password=None,
        )
        print("[KEY] PEM format OK")
    except Exception as e:
        raise ValueError(f"PRIVATE_KEY PEM format bozuk: {type(e).__name__}: {e}")


# =========================
# JWT
# =========================

def generate_jwt():
    now = int(time.time())

    payload = {
        "iss": ISSUER_ID,
        "iat": now,
        "exp": now + 300,
        "aud": "appstoreconnect-v1",
        "bid": BUNDLE_ID,
    }

    headers = {
        "alg": "ES256",
        "kid": KEY_ID,
        "typ": "JWT",
    }

    return jwt.encode(
        payload,
        load_private_key(),
        algorithm="ES256",
        headers=headers,
    )


# =========================
# CSV
# =========================

def load_ids_from_csv(file_path: str) -> List[str]:
    ids = []

    with open(file_path, newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for row in reader:
            value = row.get("apple_original_transaction_id")
            if value:
                ids.append(value.strip())

    # unique, sırayı koru
    return list(dict.fromkeys(ids))


# =========================
# JWS DECODE
# =========================

def decode_jws(token: str) -> Dict:
    try:
        parts = token.split(".")
        if len(parts) != 3:
            return {}

        payload = parts[1]
        padding = "=" * (-len(payload) % 4)
        decoded = base64.urlsafe_b64decode(payload + padding)
        return json.loads(decoded)
    except Exception:
        return {}


# =========================
# API
# =========================

def get_base_url():
    return (
        "https://api.storekit-sandbox.itunes.apple.com"
        if USE_SANDBOX
        else "https://api.storekit.itunes.apple.com"
    )


def fetch_transactions(session, otid):
    url = f"{get_base_url()}/inApps/v1/history/{otid}"

    all_txns = []
    revision = None
    prev_revision = None
    page_no = 1

    while True:
        params = {"revision": revision} if revision else {}

        headers = {
            "Authorization": f"Bearer {generate_jwt()}",
            "Accept": "application/json",
        }

        print(f"   [REQ] otid={otid} page={page_no} revision={revision}")

        try:
            res = session.get(
                url,
                headers=headers,
                params=params,
                timeout=REQUEST_TIMEOUT,
            )
        except requests.exceptions.Timeout:
            print(f"   [TIMEOUT] {otid}")
            break
        except Exception as e:
            print(f"   [REQUEST ERROR] {type(e).__name__}: {e}")
            break

        print(f"   [STATUS] {res.status_code}")

        if res.status_code != 200:
            print(f"   [ERROR BODY] {res.text[:1000]}")
            break

        try:
            data = res.json()
        except Exception as e:
            print(f"   [JSON ERROR] {type(e).__name__}: {e}")
            print(res.text[:1000])
            break

        signed_txns = data.get("signedTransactions", [])
        has_more = data.get("hasMore", False)
        revision = data.get("revision")

        print(f"   [SIGNED TXN COUNT] {len(signed_txns)} | hasMore={has_more}")

        for st in signed_txns:
            decoded = decode_jws(st)
            if decoded:
                all_txns.append(decoded)

        if len(signed_txns) == 0:
            print("   [STOP] signedTransactions boş geldi")
            break

        if not has_more:
            print("   [STOP] hasMore=false")
            break

        if revision == prev_revision:
            print("   [STOP] revision değişmedi, loop önlendi")
            break

        if not revision:
            print("   [STOP] hasMore=true ama revision yok")
            break

        prev_revision = revision
        page_no += 1

    return all_txns


# =========================
# FILTER
# =========================

def is_april_payment(txn):
    purchase_date = txn.get("purchaseDate")
    if not purchase_date:
        return False

    dt = time.gmtime(int(purchase_date) / 1000)
    return dt.tm_year == TARGET_YEAR and dt.tm_mon == TARGET_MONTH


# =========================
# MAIN
# =========================

def main():
    if not ISSUER_ID:
        raise ValueError("ISSUER_ID boş")
    if not KEY_ID:
        raise ValueError("KEY_ID boş")
    if not BUNDLE_ID:
        raise ValueError("BUNDLE_ID boş")

    validate_private_key()

    ids = load_ids_from_csv(CSV_FILE)
    print(f"Toplam ID: {len(ids)}")

    run_ids = ids if MAX_TEST_IDS == 0 else ids[:MAX_TEST_IDS]
    print(f"İşlenecek ID sayısı: {len(run_ids)}")

    april_users = []

    with requests.Session() as session:
        for i, otid in enumerate(run_ids, start=1):
            print(f"\n{i}/{len(run_ids)} → {otid}")

            txns = fetch_transactions(session, otid)
            print(f"   [TOTAL DECODED TXNS] {len(txns)}")

            april_txns = [t for t in txns if is_april_payment(t)]

            if april_txns:
                detailed_txns = []

                for txn in april_txns:
                    price_milli = txn.get("price")
                    currency = txn.get("currency")
                    transaction_id = txn.get("transactionId")
                    product_id = txn.get("productId")
                    purchase_date = txn.get("purchaseDate")
                    expires_date = txn.get("expiresDate")
                    transaction_reason = txn.get("transactionReason")

                    price_display = None
                    if price_milli is not None:
                        try:
                            price_display = float(price_milli) / 1000.0
                        except Exception:
                            price_display = None

                    detailed_txns.append({
                        "transactionId": transaction_id,
                        "productId": product_id,
                        "purchaseDate": purchase_date,
                        "expiresDate": expires_date,
                        "transactionReason": transaction_reason,
                        "priceMilli": price_milli,
                        "priceDisplay": price_display,
                        "currency": currency,
                    })

                april_users.append({
                    "originalTransactionId": otid,
                    "count": len(april_txns),
                    "transactions": detailed_txns,
                })

                print(f"   [MATCH] April transaction count = {len(april_txns)}")

    print("\n==== SONUÇ ====")
    print(f"Nisan'da transaction bulunan ID sayısı: {len(april_users)}")

    # JSON çıktısı
    with open("april_users.json", "w", encoding="utf-8") as f:
        json.dump(april_users, f, ensure_ascii=False, indent=2)

    print("Dosya yazıldı → april_users.json")

    # CSV çıktısı
    with open("april_users_detailed.csv", "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(
            f,
            fieldnames=[
                "originalTransactionId",
                "transactionId",
                "productId",
                "purchaseDate",
                "expiresDate",
                "transactionReason",
                "priceMilli",
                "priceDisplay",
                "currency",
            ],
        )
        writer.writeheader()

        for user in april_users:
            otid = user["originalTransactionId"]

            for txn in user.get("transactions", []):
                writer.writerow({
                    "originalTransactionId": otid,
                    "transactionId": txn.get("transactionId"),
                    "productId": txn.get("productId"),
                    "purchaseDate": txn.get("purchaseDate"),
                    "expiresDate": txn.get("expiresDate"),
                    "transactionReason": txn.get("transactionReason"),
                    "priceMilli": txn.get("priceMilli"),
                    "priceDisplay": txn.get("priceDisplay"),
                    "currency": txn.get("currency"),
                })

    print("Dosya yazıldı → april_users_detailed.csv")


if __name__ == "__main__":
    main()
