## Ödeme linki oluşturmak için .env içerisindeki NKOLAY_LIST_SX değerini NKOLAY_SX olarak değiştirerek aşağıdaki kodu çalıştırabilirsiniz.

import os
import json
import base64
import hashlib
import requests
from datetime import datetime
from dotenv import load_dotenv

load_dotenv()

# =========================
# ENV
# =========================

NKOLAY_BASE_URL = os.getenv(
    "NKOLAY_BASE_URL",
    "https://paynkolay.nkolayislem.com.tr"
).rstrip("/")

NKOLAY_SX = os.getenv("NKOLAY_SX", "").strip()
NKOLAY_MERCHANT_SECRET_KEY = os.getenv(
    "NKOLAY_MERCHANT_SECRET_KEY",
    ""
).strip()

DEBUG = os.getenv("DEBUG", "1") == "1"

if not NKOLAY_SX or not NKOLAY_MERCHANT_SECRET_KEY:
    raise RuntimeError(
        "Eksik env var: NKOLAY_SX / NKOLAY_MERCHANT_SECRET_KEY"
    )

# =========================
# PAYMENT LINK PARAMS
# =========================

client_ref_code = f"GAINTEST{datetime.now().strftime('%Y%m%d%H%M%S')}"

amount = "1.00"

success_url = "https://gain.tv"
fail_url = "https://gain.tv"

rnd = datetime.now().strftime("%Y%m%d%H%M%S")

use_3d = "true"

currency_code = "949"

transaction_type = "SALES"

# =========================
# HASH
# sx|clientRefCode|amount|successUrl|failUrl|rnd|customerKey|merchantSecretKey
# =========================

customer_key = ""

raw_string = (
    f"{NKOLAY_SX}|"
    f"{client_ref_code}|"
    f"{amount}|"
    f"{success_url}|"
    f"{fail_url}|"
    f"{rnd}|"
    f"{customer_key}|"
    f"{NKOLAY_MERCHANT_SECRET_KEY}"
)

sha512 = hashlib.sha512(raw_string.encode("utf-8")).digest()

hash_data_v2 = base64.b64encode(sha512).decode("utf-8")

# =========================
# REQUEST
# =========================

url = f"{NKOLAY_BASE_URL}/Vpos/by-link-create"

payload = {
    "sx": NKOLAY_SX,
    "clientRefCode": client_ref_code,
    "amount": amount,
    "successUrl": success_url,
    "failUrl": fail_url,
    "rnd": rnd,
    "use3D": use_3d,
    "currencyCode": currency_code,
    "transactionType": transaction_type,
    "hashDatav2": hash_data_v2,
}

if DEBUG:
    safe_payload = dict(payload)
    safe_payload["sx"] = "***"
    safe_payload["hashDatav2"] = "***"

    print("URL:")
    print(url)

    print("\nPAYLOAD:")
    print(json.dumps(safe_payload, indent=2, ensure_ascii=False))

resp = requests.post(
    url,
    data=payload,
    timeout=45
)

print("\nSTATUS:", resp.status_code)

try:
    response_json = resp.json()

    print("\nRESPONSE:")
    print(json.dumps(response_json, indent=2, ensure_ascii=False))

except Exception:
    print("\nRAW RESPONSE:")
    print(resp.text)