import os
import json
import argparse
from pathlib import Path
from datetime import date, datetime, timedelta, timezone
from typing import Any, Dict, List, Optional

import pandas as pd
import requests
from dotenv import load_dotenv


load_dotenv()

PAYGURU_BASE_URL = os.getenv("PAYGURU_BASE_URL", "http://api.trend-tech.net").rstrip("/")
PAYGURU_MERCHANT_ID = os.getenv("PAYGURU_MERCHANT_ID", "").strip()
PAYGURU_SERVICE_IDS = [
    s.strip()
    for s in os.getenv("PAYGURU_SERVICE_IDS", "").split(",")
    if s.strip()
]

OUT_DIR = Path(os.getenv("OUT_DIR", "./payguru_outputs"))
DEBUG = os.getenv("DEBUG", "0") == "1"

OUT_DIR.mkdir(parents=True, exist_ok=True)

if not PAYGURU_MERCHANT_ID or not PAYGURU_SERVICE_IDS:
    raise RuntimeError(
        "Eksik env var: PAYGURU_MERCHANT_ID / PAYGURU_SERVICE_IDS"
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


def search_transactions(
    start_date: date,
    end_date: date,
    service_id: str,
    page: int = 1,
    limit: int = 100
) -> Dict[str, Any]:
    url = f"{PAYGURU_BASE_URL}/MicroPayment/transactions/search"

    body = {
        "merchantId": int(PAYGURU_MERCHANT_ID),
        "serviceId": int(service_id),
        "search": [
            {
                "column": "modifiedDate",
                "term": start_date.isoformat(),
                "condition": ">="
            },
            {
                "column": "modifiedDate",
                "term": end_date.isoformat(),
                "condition": "<="
            }
        ],
        "sort": [
            {
                "column": "id",
                "asc": True
            }
        ],
        "limit": limit,
        "page": page
    }

    resp = requests.post(url, json=body, timeout=45)

    if DEBUG:
        print("URL:", url)
        print("BODY:", json.dumps(body, ensure_ascii=False, indent=2))
        print("STATUS:", resp.status_code)
        print("RESP:", resp.text[:3000])

    try:
        payload = resp.json()
    except Exception:
        payload = {"raw_response": resp.text}

    if resp.status_code == 403:
        detail = payload.get("response", {}).get("resultDetail") if isinstance(payload, dict) else None
        desc = payload.get("response", {}).get("resultDescription") if isinstance(payload, dict) else None

        raise RuntimeError(
            "[PAYGURU_AUTH_ERROR] Payguru API erişimi reddedildi.\n"
            f"Status: {resp.status_code}\n"
            f"Description: {desc}\n"
            f"Detail: {detail}\n"
            "Muhtemel sebep: IP whitelist eksik. Airflow/prod sunucu IP'si Payguru tarafında whitelist edilmeli."
        )

    if resp.status_code >= 400:
        raise RuntimeError(
            "[PAYGURU_API_ERROR]\n"
            f"Status: {resp.status_code}\n"
            f"Response: {json.dumps(payload, ensure_ascii=False)[:2000]}"
        )

    return payload

def extract_transactions(payload: Dict[str, Any]) -> List[Dict[str, Any]]:
    for key in ["transactions", "transactionList", "data", "items", "results"]:
        value = payload.get(key)
        if isinstance(value, list):
            return value

    data = payload.get("data")
    if isinstance(data, dict):
        for key in ["transactions", "items", "results"]:
            value = data.get(key)
            if isinstance(value, list):
                return value

    return []


def normalize_transaction(t: Dict[str, Any]) -> Dict[str, Any]:
    return {
        "transaction_id": str(t.get("id") or t.get("transactionId") or ""),
        "service_id": str(t.get("service") or t.get("serviceId") or PAYGURU_SERVICE_IDS),
        "merchant_id": str(t.get("merchant") or t.get("merchantId") or PAYGURU_MERCHANT_ID),

        "transaction_date": t.get("transactionDate") or t.get("createDate") or t.get("createdDate"),
        "modified_date": t.get("modifiedDate") or t.get("updateDate") or t.get("updatedDate"),

        "amount": t.get("amount") or t.get("price"),
        "currency": t.get("currency") or "TRY",

        "status": t.get("status"),
        "status_text": t.get("statusText") or t.get("statusDescription"),
        "error": t.get("error"),
        "error_detail": t.get("errorDetail"),

        "operator": t.get("operator"),
        "msisdn": t.get("msisdn"),
        "reference_code": t.get("referenceCode"),
        "subscription_id": t.get("subscriptionId") or t.get("subscription"),

        "raw_json": json.dumps(t, ensure_ascii=False),
    }


def fetch_transactions(start_date, end_date):
    all_rows = []

    for service_id in PAYGURU_SERVICE_IDS:
        print(f"[INFO] service_id={service_id} çekiliyor...")

        page = 1
        limit = 100

        while True:
            payload = search_transactions(
                start_date=start_date,
                end_date=end_date,
                service_id=service_id,
                page=page,
                limit=limit,
            )

            txs = extract_transactions(payload)
            print(f"[INFO] service_id={service_id} page={page} tx_count={len(txs)}")

            for tx in txs:
                row = normalize_transaction(tx)
                row["service_id"] = service_id
                all_rows.append(row)

            if len(txs) < limit:
                break

            page += 1

    return pd.DataFrame(all_rows)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=["daily", "manual", "monthly", "custom"])
    parser.add_argument("--start-date")
    parser.add_argument("--end-date")
    args = parser.parse_args()

    start_date, end_date = resolve_dates(args.mode, args.start_date, args.end_date)

    df = fetch_transactions(start_date, end_date)

    output_file = OUT_DIR / (
        f"payguru_transactions_{args.mode}_{start_date.strftime('%Y%m%d')}_to_{end_date.strftime('%Y%m%d')}.csv"
    )

    df.to_csv(output_file, index=False, encoding="utf-8-sig")

    print(f"[OK] Rows: {len(df)}")
    print(f"[OK] Saved: {output_file}")


if __name__ == "__main__":
    main()