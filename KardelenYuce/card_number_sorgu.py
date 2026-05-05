import os
import time
import requests
from typing import Optional, Dict, Any

BASE = "https://api.gain.tv/2da7kf8jf"
CULTURE = "__culture=tr-tr"

USER_LIST_URL = f"{BASE}/CALL/User/getUserList/default?{CULTURE}"
def USER_DETAIL_URL(uid: str) -> str:
    return f"{BASE}/CALL/User/getUserDetailForBo/{uid}?{CULTURE}"

# TOKEN aynen kalsın (ama env varsa onu kullanır)
TOKEN = os.getenv(
    "GAIN_BO_TOKEN",
    "Bearer eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.eyJwcm9qZWN0SWQiOiIyZGE3a2Y4amYiLCJpZGVudGl0eSI6ImJhY2tvZmZpY2VfdXNlciIsImFub255bW91cyI6ZmFsc2UsInVzZXJJZCI6IlJpTmtLYnRTTzQ3WlB2UTMxSHhWQ3hoeCIsImNsYWltcyI6eyJuYW1lIjoiS2FyZGVsZW4gWcO8Y2UiLCJlbWFpbCI6ImthcmRlbGVueXVjZUBnYWluLmNvbS50ciIsInN0YXR1cyI6ImFjdGl2ZSIsInJvbGUiOiJhZG1pbiJ9LCJzZXNzaW9uSWQiOiI0ZjMyYzU2MGYyZmU0OTM3YmI0ZDQwNmUwNmQwMGY4MyIsImlhdCI6MTc2OTY3MTM3NiwiZXhwIjoxNzcyMjYzMzc2fQ.yWp1U0Y843nr-A7xE_kUi_CFYyaxxhfowdOB6L0LDcjEXJ-6X4b_tqBnfIf1ygyva8aBwQKqYbZge8zrIWZv6y6NvJZN3uPwco8GaYm2FxWnt06eXdlUMiuG1ANt-HVazwvwZfPCOYoBmTq5x5fG7sMCqZbQZFYuTnBKMuujZRe6Mnw0Zbn2Qu8poyl2HF0jzfGR9ArFkijWbC7oaIahEXo8W_PKqpGYaX4IZ7AN2d4iwc7wo6pkLlcY5ztIseVn8J4Dajdd0X0-TJXAlN24szrxvahgMMbJr1FnTjQAk3G0frIgyEYfnBVgIyzFzb0bK4TE_--3eZTXguMjvBkctA"
).strip()

if not TOKEN:
    raise SystemExit("GAIN_BO_TOKEN env boş")

HEADERS = {
    "Content-Type": "application/json",
    "Authorization": TOKEN,
}

TIMEOUT = 30
SLEEP_SEC = 0.06  # rate-limit için

# Aralık 2025 (ms)  ✅ (print metnini de buna göre düzelttim)
START_MS = 1752440400000
END_MS   = 1752526799999

TARGET_LAST4 = "8255"

LIST_QUERY = (
    "NOT status:DELETED "
    f"AND createdAt:[{START_MS} TO {END_MS}] "
    "AND subscription.paymentOption:CRAFTGATE"
)

def extract_uid(row: Dict[str, Any]) -> Optional[str]:
    return row.get("userId") or row.get("id") or row.get("customerId")

def safe_json(r: requests.Response) -> Dict[str, Any]:
    try:
        return r.json()
    except Exception:
        return {"_raw": r.text}

def get_user_page(offset: int, page_size: int) -> Dict[str, Any]:
    payload = {
        "query": LIST_QUERY,
        "from": offset,
        "pageSize": page_size,
        "sorts": [{"createdAt": "desc"}],
    }
    r = requests.post(USER_LIST_URL, json=payload, headers=HEADERS, timeout=TIMEOUT)

    if r.status_code in (401, 403):
        data = safe_json(r)
        raise SystemExit(f"Auth error {r.status_code}: {data}")

    if r.status_code == 429:
        # basit backoff
        time.sleep(1.0)
        r = requests.post(USER_LIST_URL, json=payload, headers=HEADERS, timeout=TIMEOUT)

    r.raise_for_status()
    return safe_json(r)

def unwrap_result(d: Dict[str, Any]) -> Dict[str, Any]:
    # Bazı endpointler { result: {...}, meta: ... } döndürüyor.
    # Bazıları direkt {...} döndürebiliyor.
    if isinstance(d.get("result"), dict):
        return d["result"]
    return d

def get_user_detail(uid: str) -> Dict[str, Any]:
    url = USER_DETAIL_URL(uid)

    # Çoğu zaman GET çalışır; POST 405 verirse GET'e düş
    r = requests.post(url, json={}, headers=HEADERS, timeout=TIMEOUT)
    if r.status_code == 405:
        r = requests.get(url, headers=HEADERS, timeout=TIMEOUT)

    if r.status_code in (401, 403):
        data = safe_json(r)
        raise SystemExit(f"Auth error {r.status_code} (detail): {data}")

    if r.status_code == 429:
        time.sleep(1.0)
        r = requests.get(url, headers=HEADERS, timeout=TIMEOUT)

    r.raise_for_status()
    return unwrap_result(safe_json(r))

def match_card(detail: Dict[str, Any]) -> bool:
    # 1) cardDetails[].lastFourDigits
    for cd in (detail.get("cardDetails") or []):
        l4 = str(cd.get("lastFourDigits") or "")
        if l4 == TARGET_LAST4:
            return True

    # 2) subscription.cardNumber (maskeli string)
    sub = detail.get("subscription") or {}
    cn = str(sub.get("cardNumber") or "").replace(" ", "")
    if cn.endswith(TARGET_LAST4):
        return True

    return False

def main(page_size: int = 50) -> None:
    first = get_user_page(0, page_size)
    meta = first.get("meta", {}) or {}
    total = int(meta.get("total") or 0)

    print("=== 2025 ===")
    print("total users:", total)
    print("TARGET_LAST4:", TARGET_LAST4)
    print("---------------------------")

    checked = 0
    hits = 0
    offset = 0

    while True:
        page = get_user_page(offset, page_size)
        rows = page.get("result", []) or []
        if not rows:
            break

        for row in rows:
            uid = extract_uid(row)
            if not uid:
                continue

            detail = get_user_detail(uid)
            checked += 1

            if match_card(detail):
                hits += 1
                sub = detail.get("subscription") or {}
                print(f"\n🎯 CARD HIT (last4={TARGET_LAST4})")
                print("userId             :", uid)
                print("fullName           :", detail.get("fullName"))
                print("email              :", detail.get("email"))
                print("userCreatedAt      :", row.get("createdAt"))
                print("subscriptionStatus :", sub.get("status"))
                print("paymentOption      :", sub.get("paymentOption"))
                print("cardNumberMasked   :", sub.get("cardNumber"))
                print("-" * 40)

            if checked % 50 == 0:
                print(f"checked={checked}/{total} hits={hits}")

            time.sleep(SLEEP_SEC)

        offset += page_size
        if total and offset >= total:
            break

    print("\nDONE ✅")
    print("TOTAL CHECKED:", checked)
    print("TOTAL HITS   :", hits)

if __name__ == "__main__":
    main(page_size=50)
