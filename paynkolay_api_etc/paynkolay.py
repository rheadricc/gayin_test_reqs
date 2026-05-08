## Ödemelerin dökümünü almak için .env içerisindeki NKOLAY_SX değerini NKOLAY_LIST_SX olarak değiştirerek aşağıdaki kodu çalıştırabilirsiniz.

import os
import json
import base64
import hashlib
import argparse
from pathlib import Path
from datetime import date, datetime, timedelta, timezone
from typing import Optional, Any, Dict, List

import pandas as pd
import requests
from dotenv import load_dotenv


load_dotenv()

NKOLAY_BASE_URL = os.getenv(
    "NKOLAY_BASE_URL",
    "https://paynkolaytest.nkolayislem.com.tr"
).rstrip("/")

NKOLAY_LIST_SX = os.getenv("NKOLAY_LIST_SX", "").strip()
NKOLAY_MERCHANT_SECRET_KEY = os.getenv("NKOLAY_MERCHANT_SECRET_KEY", "").strip()

OUT_DIR = Path(os.getenv("OUT_DIR", "./nkolay_outputs"))
DEBUG = os.getenv("DEBUG", "0") == "1"

OUT_DIR.mkdir(parents=True, exist_ok=True)

if not NKOLAY_LIST_SX or not NKOLAY_MERCHANT_SECRET_KEY:
    raise RuntimeError(
        "Eksik env var: NKOLAY_LIST_SX / NKOLAY_MERCHANT_SECRET_KEY"
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


def format_nkolay_date(d: date) -> str:
    return d.strftime("%d.%m.%Y")


def build_hash(sx: str, start_date: str, end_date: str, client_ref_code: str) -> str:
    raw = f"{sx}|{start_date}|{end_date}|{client_ref_code}|{NKOLAY_MERCHANT_SECRET_KEY}"
    digest = hashlib.sha512(raw.encode("utf-8")).digest()
    return base64.b64encode(digest).decode("utf-8")


def payment_list(start_date: date, end_date: date, client_ref_code: str = "") -> Dict[str, Any]:
    url = f"{NKOLAY_BASE_URL}/Vpos/Payment/PaymentList"

    start_str = format_nkolay_date(start_date)
    end_str = format_nkolay_date(end_date)

    hash_data = build_hash(
        sx=NKOLAY_LIST_SX,
        start_date=start_str,
        end_date=end_str,
        client_ref_code=client_ref_code,
    )

    data = {
        "sx": NKOLAY_LIST_SX,
        "startDate": start_str,
        "endDate": end_str,
        "clientRefCode": client_ref_code,
        "hashDatav2": hash_data,
    }

    resp = requests.post(url, data=data, timeout=45)

    if DEBUG:
        safe_data = dict(data)
        safe_data["sx"] = "***"
        safe_data["hashDatav2"] = "***"
        print("URL:", url)
        print("FORM:", json.dumps(safe_data, ensure_ascii=False, indent=2))
        print("STATUS:", resp.status_code)
        print("RESP:", resp.text[:3000])

    try:
        payload = resp.json()
    except Exception:
        payload = {"raw_response": resp.text}

    if resp.status_code >= 400:
        raise RuntimeError(
            "[NKOLAY_API_ERROR]\n"
            f"Status: {resp.status_code}\n"
            f"Response: {json.dumps(payload, ensure_ascii=False)[:2000]}"
        )

    return payload


def extract_transactions(payload: Dict[str, Any]) -> List[Dict[str, Any]]:
    # Bazı response'larda result string olarak geliyor.
    result = payload.get("result")

    if isinstance(result, str):
        try:
            result = json.loads(result)
        except Exception:
            return []

    if isinstance(result, dict):
        txs = result.get("LIST")
        if isinstance(txs, list):
            return txs

        response_data = result.get("RESPONSE_DATA")
        if isinstance(response_data, list):
            return response_data

    # Olası diğer formatlar için fallback
    for key in [
        "LIST",
        "list",
        "data",
        "Data",
        "transactions",
        "Transactions",
        "paymentList",
        "PaymentList",
    ]:
        value = payload.get(key)
        if isinstance(value, list):
            return value

    return []


def parse_amount(value):
    if value in [None, ""]:
        return None
    try:
        return float(str(value).replace(",", "."))
    except Exception:
        return None


def parse_nkolay_datetime(value):
    if not value:
        return None

    parsed = pd.to_datetime(value, dayfirst=True, errors="coerce")
    return parsed.isoformat() if pd.notna(parsed) else None


def parse_nkolay_date(value):
    if not value:
        return None

    # Örn: 20260508
    parsed = pd.to_datetime(value, format="%Y%m%d", errors="coerce")
    return parsed.date().isoformat() if pd.notna(parsed) else None


def normalize_transaction(t: Dict[str, Any]) -> Dict[str, Any]:
    return {
        "transaction_id": str(t.get("OID") or ""),
        "reference_code": str(t.get("REFERENCE_CODE") or ""),
        "client_reference_code": str(t.get("CLIENT_REFERENCE_CODE") or ""),
        "auth_code": str(t.get("AUTH_CODE") or ""),

        "transaction_date": parse_nkolay_datetime(t.get("TRX_DATE")),
        "valor_date": parse_nkolay_date(t.get("VALOR_DATE")),

        "transaction_type": str(t.get("TRANSACTION_TYPE") or ""),
        "status": str(t.get("STATUS") or ""),
        "description": str(t.get("DESCRIPTION") or ""),

        "transaction_amount": parse_amount(t.get("TRANSACTION_AMOUNT")),
        "authorization_amount": parse_amount(t.get("AUTHORIZATION_AMOUNT")),
        "commission_amount": parse_amount(t.get("COMMISION")),
        "merchant_commission_amount": parse_amount(t.get("MERCHANT_COMMISSION_AMOUNT")),

        "currency": "TRY",

        "card_number_masked": str(t.get("CARD_NUMBER") or ""),
        "card_holder_name": str(t.get("CARD_HOLDER_NAME") or ""),
        "card_bank_code": str(t.get("CARD_BANK_CODE") or ""),
        "card_bank_name": str(t.get("CARD_BANK_NAME") or ""),

        "pos_type": str(t.get("POS_TYPE") or ""),
        "terminal_name": str(t.get("TERMINAL_NAME") or ""),
        "is_3d": t.get("IS_3D"),
        "installment_count": str(t.get("INSTALLMENT_COUNT") or ""),

        "user_email": str(t.get("USER_EMAIL") or ""),
        "merchant_customer_no": str(t.get("MERCHANT_CUSTOMER_NO") or ""),

        "bank_result": str(t.get("BANK_RESULT") or ""),

        "source": "nkolay",
        "raw_json": json.dumps(t, ensure_ascii=False),
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=["daily", "manual", "monthly", "custom"])
    parser.add_argument("--start-date")
    parser.add_argument("--end-date")
    args = parser.parse_args()

    start_date, end_date = resolve_dates(args.mode, args.start_date, args.end_date)

    payload = payment_list(start_date, end_date, client_ref_code="")
    transactions = extract_transactions(payload)

    print(f"[INFO] tx_count={len(transactions)}")

    if transactions:
        df = pd.DataFrame([normalize_transaction(t) for t in transactions])
    else:
        df = pd.DataFrame([{
            "source": "nkolay",
            "raw_json": json.dumps(payload, ensure_ascii=False),
        }])

    output_file = OUT_DIR / (
        f"nkolay_transactions_{args.mode}_{start_date.strftime('%Y%m%d')}_to_{end_date.strftime('%Y%m%d')}.csv"
    )

    df.to_csv(output_file, index=False, encoding="utf-8-sig")

    print(f"[OK] Saved: {output_file}")


if __name__ == "__main__":
    main()