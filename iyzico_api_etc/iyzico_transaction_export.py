import os
import json
import time
import hmac
import base64
import hashlib
import secrets
import argparse
from pathlib import Path
from datetime import date, datetime, timedelta
from typing import Any, Dict, List, Optional

import pandas as pd
import requests
from dotenv import load_dotenv


# =============================
# ENV
# =============================
load_dotenv(dotenv_path=Path(__file__).resolve().parent / ".env")

IYZICO_BASE_URL = os.getenv("IYZICO_BASE_URL", "https://api.iyzipay.com").rstrip("/")
IYZICO_API_KEY = os.getenv("IYZICO_API_KEY", "").strip()
IYZICO_SECRET_KEY = os.getenv("IYZICO_SECRET_KEY", "").strip()

OUT_DIR = Path(os.getenv("OUT_DIR", "./iyzico_outputs"))
DEBUG = os.getenv("DEBUG", "0").strip() == "1"

OUT_DIR.mkdir(parents=True, exist_ok=True)

if not IYZICO_API_KEY or not IYZICO_SECRET_KEY:
    raise RuntimeError(
        "Eksik env var:\n"
        "  IYZICO_API_KEY=...\n"
        "  IYZICO_SECRET_KEY=...\n"
        "  IYZICO_BASE_URL=https://api.iyzipay.com\n"
    )


S = requests.Session()
S.headers.update({
    "Content-Type": "application/json",
    "Accept": "application/json",
})


# =============================
# IYZWSv2 SIGNING
# =============================
def random_key() -> str:
    ms = int(time.time() * 1000)
    r = secrets.randbelow(10**10)
    return f"{ms}{r:010d}"


def compact_json(obj: Dict[str, Any]) -> str:
    return json.dumps(obj, ensure_ascii=False, separators=(",", ":"))


def iyzws_headers(uri_path: str, body_obj: Optional[Dict[str, Any]] = None) -> Dict[str, str]:
    rnd = random_key()
    body_str = "" if body_obj is None else compact_json(body_obj)
    payload = f"{rnd}{uri_path}{body_str}"

    signature = hmac.new(
        IYZICO_SECRET_KEY.encode("utf-8"),
        payload.encode("utf-8"),
        hashlib.sha256,
    ).hexdigest()

    auth_string = f"apiKey:{IYZICO_API_KEY}&randomKey:{rnd}&signature:{signature}"
    encoded_auth = base64.b64encode(auth_string.encode("utf-8")).decode("utf-8")

    return {
        "Authorization": f"IYZWSv2 {encoded_auth}",
        "x-iyzi-rnd": rnd,
        "Content-Type": "application/json",
        "Accept": "application/json",
    }


# =============================
# API
# =============================
def get_daily_transactions(day_iso: str, page: int = 1, locale: str = "tr") -> Dict[str, Any]:
    uri = "/v2/reporting/payment/transactions"
    url = f"{IYZICO_BASE_URL}{uri}"

    params = {
        "transactionDate": day_iso,
        "page": page,
        "locale": locale,
    }

    resp = S.get(
        url,
        params=params,
        headers=iyzws_headers(uri),
        timeout=45,
    )

    if DEBUG:
        print("URL:", resp.url)
        print("STATUS:", resp.status_code)
        print(resp.text[:2000])

    resp.raise_for_status()
    return resp.json()


def extract_transactions(payload: Dict[str, Any]) -> List[Dict[str, Any]]:
    if isinstance(payload.get("transactions"), list):
        return payload["transactions"]

    data = payload.get("data")
    if isinstance(data, dict) and isinstance(data.get("transactions"), list):
        return data["transactions"]

    return []


def has_more(payload: Dict[str, Any], current_page: int, txs: List[Dict[str, Any]]) -> bool:
    meta = payload.get("meta") or payload.get("pagination") or payload.get("pageInfo")

    if isinstance(meta, dict):
        page_count = meta.get("pageCount") or meta.get("totalPage") or meta.get("totalPages")
        if isinstance(page_count, int):
            return current_page < page_count

    return len(txs) > 0


# =============================
# NORMALIZATION
# =============================
def normalize_transaction(t: Dict[str, Any], report_date: str) -> Dict[str, Any]:
    """
    Iyzico'dan gelen ham transaction JSON'unu
    BigQuery/CSV için sabit kolon formatına çevirir.
    """

    transaction_id = (
        t.get("transactionId")
        or t.get("paymentTransactionId")
        or t.get("iyziTransactionId")
    )

    payment_tx_id = t.get("paymentTxId")

    transaction_date = (
        t.get("transactionDate")
        or t.get("createdDate")
        or report_date
    )

    transaction_type = (
        t.get("transactionType")
        or t.get("type")
    )

    transaction_status = (
        t.get("transactionStatus")
        or t.get("paymentStatus")
        or t.get("status")
    )

    currency = (
        t.get("transactionCurrency")
        or t.get("currency")
        or t.get("currencyCode")
        or t.get("paidCurrency")
        or t.get("settlementCurrency")
    )

    amount = (
        t.get("paidPrice")
        or t.get("price")
        or t.get("amount")
        or t.get("paymentAmount")
    )

    return {
        # Ana kimlikler
        "transaction_id": str(transaction_id or ""),
        "payment_tx_id": str(payment_tx_id or ""),
        "payment_id": str(t.get("paymentId") or ""),
        "conversation_id": str(t.get("conversationId") or ""),
        "basket_id": str(t.get("basketId") or ""),

        # Tarihler
        "transaction_date": transaction_date,
        "report_date": report_date,

        # Durum / tip
        "transaction_type": str(transaction_type or ""),
        "transaction_status": str(transaction_status or ""),
        "payment_phase": t.get("paymentPhase"),
        "after_settlement": t.get("afterSettlement"),

        # Tutar / para birimi
        "price": t.get("price"),
        "paid_price": t.get("paidPrice"),
        "amount": amount,
        "transaction_currency": t.get("transactionCurrency"),
        "settlement_currency": t.get("settlementCurrency"),
        "currency": currency,

        # Taksit / 3DS
        "installment": t.get("installment"),
        "three_ds": t.get("threeDS"),

        # Iyzico komisyon / payout alanları
        "iyzico_commission": t.get("iyzicoCommission"),
        "iyzico_fee": t.get("iyzicoFee"),
        "merchant_payout_amount": t.get("merchantPayoutAmount"),
        "sub_merchant_payout_amount": t.get("subMerchantPayoutAmount"),
        "parity": t.get("parity"),
        "iyzico_conversion_amount": t.get("iyzicoConversionAmount"),

        # POS / banka referansları
        "connector_type": t.get("connectorType") or t.get("connector"),
        "pos_order_id": t.get("posOrderId"),
        "auth_code": t.get("authCode"),
        "host_reference": t.get("hostReference"),

        # Ham veri
        "raw_json": json.dumps(t, ensure_ascii=False),
    }


# =============================
# EXPORT
# =============================
def daterange(start: date, end: date):
    d = start
    while d <= end:
        yield d
        d += timedelta(days=1)


def fetch_transactions(start_date: date, end_date: date) -> pd.DataFrame:
    rows: List[Dict[str, Any]] = []

    print(f"[INFO] Iyzico transactions çekiliyor: {start_date}..{end_date}")

    for d in daterange(start_date, end_date):
        day_iso = d.isoformat()
        page = 1

        while True:
            payload = get_daily_transactions(day_iso, page=page, locale="tr")
            txs = extract_transactions(payload)

            print(f"[INFO] {day_iso} page={page} tx_count={len(txs)}")

            for tx in txs:
                rows.append(normalize_transaction(tx, report_date=day_iso))

            if not has_more(payload, page, txs):
                break

            page += 1

    return pd.DataFrame(rows)


def resolve_dates(mode: str, start_arg: Optional[str], end_arg: Optional[str]):
    today = datetime.utcnow().date()
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
            raise ValueError("custom mode için --start-date ve --end-date zorunlu")
        return date.fromisoformat(start_arg), date.fromisoformat(end_arg)

    raise ValueError("mode daily/manual/monthly/custom olmalı")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "mode",
        choices=["daily", "manual", "monthly", "custom"],
        help="daily=T-1, manual=ay başı..T-1, monthly=önceki ay, custom=tarih aralığı",
    )
    parser.add_argument("--start-date", help="YYYY-MM-DD")
    parser.add_argument("--end-date", help="YYYY-MM-DD")
    args = parser.parse_args()

    start_date, end_date = resolve_dates(args.mode, args.start_date, args.end_date)

    df = fetch_transactions(start_date, end_date)

    output_file = OUT_DIR / (
        f"iyzico_transactions_{args.mode}_{start_date.strftime('%Y%m%d')}_to_{end_date.strftime('%Y%m%d')}.csv"
    )

    df.to_csv(output_file, index=False, encoding="utf-8-sig")

    print(f"[OK] Rows: {len(df)}")
    print(f"[OK] Saved: {output_file}")


if __name__ == "__main__":
    main()