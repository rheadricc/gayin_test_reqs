import os
import time
import json
import argparse
import requests
import pandas as pd
from pathlib import Path
from datetime import date, datetime, timedelta, timezone
from lxml import etree
from dotenv import load_dotenv


# =========================
# ENV
# =========================
load_dotenv(dotenv_path=Path(__file__).resolve().parent / ".env")

SOAP_URL = os.getenv(
    "TURKPOS_SOAP_URL",
    "https://posws.param.com.tr/turkpos.ws/service_turkpos_prod.asmx",
).strip()

CLIENT_CODE = os.getenv("TURKPOS_CLIENT_CODE", "").strip()
CLIENT_USERNAME = os.getenv("TURKPOS_CLIENT_USERNAME", "").strip()
CLIENT_PASSWORD = os.getenv("TURKPOS_CLIENT_PASSWORD", "").strip()
GUID = os.getenv("TURKPOS_GUID", "").strip()

OUT_DIR = Path(os.getenv("OUT_DIR", "./param_outputs"))
DEBUG = os.getenv("DEBUG", "0") == "1"
SLEEP_SEC = float(os.getenv("SLEEP_SEC", "0.2"))

OUT_DIR.mkdir(parents=True, exist_ok=True)

if not all([SOAP_URL, CLIENT_CODE, CLIENT_USERNAME, CLIENT_PASSWORD, GUID]):
    raise RuntimeError("Eksik env var: TURKPOS_* değerlerini kontrol et.")


# =========================
# DATE
# =========================
def resolve_dates(mode: str, start_arg=None, end_arg=None):
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
            raise ValueError("custom mode için --start-date ve --end-date zorunlu")
        return date.fromisoformat(start_arg), date.fromisoformat(end_arg)

    raise ValueError("mode daily/manual/monthly/custom olmalı")


def daterange(start: date, end: date):
    cur = start
    while cur <= end:
        yield cur
        cur += timedelta(days=1)


# =========================
# SOAP
# =========================
def build_mutabakat_xml(day: date) -> str:
    tarih_str = day.strftime("%d.%m.%Y 00:00:00")

    return f"""<?xml version="1.0" encoding="utf-8"?>
<soap:Envelope xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
               xmlns:xsd="http://www.w3.org/2001/XMLSchema"
               xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">
  <soap:Body>
    <TP_Mutabakat_Detay xmlns="https://turkpos.com.tr/">
      <G>
        <CLIENT_CODE>{CLIENT_CODE}</CLIENT_CODE>
        <CLIENT_USERNAME>{CLIENT_USERNAME}</CLIENT_USERNAME>
        <CLIENT_PASSWORD>{CLIENT_PASSWORD}</CLIENT_PASSWORD>
      </G>
      <GUID>{GUID}</GUID>
      <Tarih>{tarih_str}</Tarih>
    </TP_Mutabakat_Detay>
  </soap:Body>
</soap:Envelope>"""


def post_soap(xml_body: str) -> bytes:
    headers = {
        "Content-Type": "text/xml; charset=utf-8",
        "SOAPAction": '"https://turkpos.com.tr/TP_Mutabakat_Detay"',
    }

    resp = requests.post(
        SOAP_URL,
        data=xml_body.encode("utf-8"),
        headers=headers,
        timeout=45,
    )

    if DEBUG:
        print("STATUS:", resp.status_code)
        print(resp.text[:1000])

    resp.raise_for_status()
    return resp.content


def parse_mutabakat_rows(xml_bytes: bytes) -> list[dict]:
    root = etree.fromstring(xml_bytes)
    nodes = root.xpath("//*[local-name()='DT_Mutabakat_Detay']")

    rows = []
    for node in nodes:
        row = {}
        for child in node:
            key = etree.QName(child).localname
            row[key] = (child.text or "").strip()
        rows.append(row)

    return rows


# =========================
# NORMALIZE
# =========================
def parse_tr_amount(value):
    if value is None or value == "":
        return None

    return float(
        str(value)
        .replace(".", "")
        .replace(",", ".")
        .strip()
    )


def parse_tr_datetime(value):
    if not value:
        return None

    parsed = pd.to_datetime(value, dayfirst=True, errors="coerce")
    return parsed.isoformat() if pd.notna(parsed) else None


def normalize_transaction(row: dict, source_date: str) -> dict:
    return {
        "transaction_id": row.get("PROVIZYON_NO") or "",
        "order_id": row.get("SIPARIS_NO") or "",

        "transaction_date": parse_tr_datetime(row.get("ISLEM_TARIHI")),
        "settlement_date": row.get("VALOR_TARIHI") or "",
        "batch_close_date": parse_tr_datetime(row.get("GUNSONU_TARIHI")),

        "transaction_type": row.get("TRANSACTION_TIPI") or "",
        "currency": "TRY",

        "gross_amount": parse_tr_amount(row.get("PROVIZYON_TUTARI")),
        "commission_amount": parse_tr_amount(row.get("KOMISYON_TUTARI")),
        "commission_rate": parse_tr_amount(row.get("KOMISYON_ORANI")),
        "net_amount": parse_tr_amount(row.get("NET_TUTAR")),

        "installment_index": row.get("TAKSIT_SIRASI") or "",
        "installment_count": row.get("TAKSIT_SAYISI") or "",

        "card_masked": row.get("KART_NO") or "",
        "card_type": row.get("ANA_KART_TIPI") or "",
        "bank": row.get("ALT_KART_TIPI") or "",

        "source": "param",
        "source_date": source_date,
        "raw_json": json.dumps(row, ensure_ascii=False),
    }


# =========================
# FETCH
# =========================
def fetch_transactions(start_date: date, end_date: date) -> pd.DataFrame:
    rows = []

    print(f"[INFO] Param transactions çekiliyor: {start_date}..{end_date}")

    for day in daterange(start_date, end_date):
        xml = build_mutabakat_xml(day)
        resp = post_soap(xml)
        raw_rows = parse_mutabakat_rows(resp)

        print(f"[INFO] {day} rows={len(raw_rows)}")

        for raw in raw_rows:
            rows.append(normalize_transaction(raw, source_date=str(day)))

        time.sleep(SLEEP_SEC)

    return pd.DataFrame(rows)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=["daily", "manual", "monthly", "custom"])
    parser.add_argument("--start-date")
    parser.add_argument("--end-date")
    args = parser.parse_args()

    start_date, end_date = resolve_dates(args.mode, args.start_date, args.end_date)
    df = fetch_transactions(start_date, end_date)

    output_file = OUT_DIR / (
        f"param_transactions_{args.mode}_{start_date.strftime('%Y%m%d')}_to_{end_date.strftime('%Y%m%d')}.csv"
    )

    df.to_csv(output_file, index=False, encoding="utf-8-sig")

    print(f"[OK] Rows: {len(df)}")
    print(f"[OK] Saved: {output_file}")


if __name__ == "__main__":
    main()