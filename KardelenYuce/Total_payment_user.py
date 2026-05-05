import os
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from typing import Dict, Any, List, Optional

import pandas as pd
import requests

BASE_URL = "https://api.gain.tv/2da7kf8jf"
AUTH_TOKEN = "Bearer eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.eyJwcm9qZWN0SWQiOiIyZGE3a2Y4amYiLCJpZGVudGl0eSI6ImJhY2tvZmZpY2VfdXNlciIsImFub255bW91cyI6ZmFsc2UsInVzZXJJZCI6IlJpTmtLYnRTTzQ3WlB2UTMxSHhWQ3hoeCIsImNsYWltcyI6eyJuYW1lIjoiS2FyZGVsZW4gWcO8Y2UiLCJlbWFpbCI6ImthcmRlbGVueXVjZUBnYWluLmNvbS50ciIsInN0YXR1cyI6ImFjdGl2ZSIsInJvbGUiOiJhZG1pbiJ9LCJzZXNzaW9uSWQiOiIzY2VjY2ZmZmYwMTM0ZDJhOTI5NTY4YWM3MGQ4NjE5ZCIsImlhdCI6MTc3Mzc1MTY3MiwiZXhwIjoxNzc2MzQzNjcyfQ.tqJ5xoefcQ1EnxxXqTySyzh6exeCUjzNPHZOcGM8St5GeFOg37oDJirwWPWOUfPXOc9slgx9xvY-H47g3QIje1VPmeg_aBE1n7QaoihgUCukOgw0Fc2rUBg24rNmamJeoe7N_BSDtoF_SiEjER-13WfMcuNRBjDomTHpuxTk2bDPlOVFLzbwXnOZrr-9wQFGKziU1OJK3tdR-y-A48FIIUJsSqQKBDavXWHN_34ewCYZ19965xcgi-eAmgTdrWNQlYnHSlRnBrdW8cHUDsyQ87pW2m8EE0rrv-s3edcOcgiqi2cMKklt-m4m95nLxeXbg5yPjk3-NR_nlXpCO5ZKtg"

LIST_URL = f"{BASE_URL}/CALL/User/getUserList/default?__culture=tr-tr"
DETAIL_URL_TMPL = f"{BASE_URL}/CALL/User/getUserDetailForBo/{{user_id}}?__culture=tr-tr"

HEADERS = {
    "Authorization": AUTH_TOKEN,
    "Content-Type": "application/json",
    "Accept": "application/json",
}

QUERY_ACTIVE = "NOT status:DELETED AND subscription.status:active"
PAGE_SIZE = 100
MAX_WORKERS = 20

OUTPUT_FILE = "active_subscribers_bo.xlsx"
CHECKPOINT_FILE = "active_subscribers_checkpoint.csv"
FLUSH_EVERY = 200  # Her 200 sonuçta bir diske yaz


def format_date(date_str: Optional[str]) -> str:
    if not date_str:
        return ""
    try:
        yyyy, mm, dd = date_str[:10].split("-")
        return f"{dd}/{mm}/{yyyy}"
    except Exception:
        return str(date_str)


def format_amount(amount, currency):
    if amount is None or amount == "":
        return ""
    try:
        amount = float(amount)
        amount_str = f"{amount:,.2f}".replace(",", "X").replace(".", ",").replace("X", ".")
    except Exception:
        amount_str = str(amount)
    return f"{amount_str} {currency}" if currency else amount_str


def fetch_user_list_page(offset: int, page_size: int = PAGE_SIZE):
    body = {
        "query": QUERY_ACTIVE,
        "from": offset,
        "pageSize": page_size,
        "sorts": [{"createdAt": "desc"}],
    }

    r = requests.post(LIST_URL, json=body, headers=HEADERS, timeout=(10, 60))
    print("LIST STATUS:", r.status_code)

    if r.status_code != 200:
        print("LIST RESPONSE:", r.text[:1000])

    r.raise_for_status()
    return r.json()


def extract_users(payload: Dict[str, Any]) -> List[Dict[str, Any]]:
    users = (
        payload.get("data")
        or payload.get("items")
        or payload.get("users")
        or payload.get("result")
        or []
    )

    result = []
    for u in users:
        user_id = u.get("userId") or u.get("id") or u.get("uuid")
        email = u.get("email", "")
        if user_id:
            result.append({
                "user_id": user_id,
                "email": email
            })
    return result


def fetch_page_one_by_one(offset: int, count: int, page_label: str):
    recovered = []
    skipped = []
    for i in range(count):
        try:
            payload = fetch_user_list_page(offset + i, page_size=1)
            page_users = extract_users(payload)
            if page_users:
                recovered.append(page_users[0])
        except Exception:
            skipped.append(offset + i)

    if skipped:
        print(f"⚠ {page_label} - Atlanan offset'ler: {skipped}")
    return recovered


def fetch_all_users():
    first = fetch_user_list_page(0)
    meta = first.get("meta", {})

    total_pages = int(meta.get("totalPage", 1))
    per_page = int(meta.get("perPage", PAGE_SIZE))

    users = extract_users(first)
    print(f"Page 1 tamamlandı: {len(users)} kullanıcı")

    for page in range(2, total_pages + 1):
        offset = (page - 1) * per_page
        try:
            payload = fetch_user_list_page(offset, page_size=per_page)
            page_users = extract_users(payload)
            users.extend(page_users)
            print(f"Page {page}/{total_pages} tamamlandı - toplam: {len(users)}")
        except Exception as e:
            print(f"Page {page}/{total_pages} HATA: {e}")
            print(f"→ Sayfa tek tek deneniyor (offset {offset}-{offset + per_page - 1})...")
            recovered = fetch_page_one_by_one(offset, per_page, f"Page {page}")
            users.extend(recovered)
            print(f"→ {len(recovered)}/{per_page} kullanıcı kurtarıldı - toplam: {len(users)}")

    return users


def fetch_detail(user_id: str):
    url = DETAIL_URL_TMPL.format(user_id=user_id)
    r = requests.get(url, headers=HEADERS, timeout=(10, 60))
    print(f"DETAIL {user_id} STATUS:", r.status_code)

    if r.status_code != 200:
        print("DETAIL RESPONSE:", r.text[:1000])

    r.raise_for_status()
    return r.json()


def parse_user(user: Dict[str, Any], payload: Dict[str, Any]) -> Dict[str, Any]:
    subscription = payload.get("subscription", {})

    return {
        "Email": user["email"],
        "User ID": user["user_id"],
        "Geçerlilik Tarihi": format_date(subscription.get("validUntil")),
        "Kapanış Tarihi": format_date(subscription.get("graceUntil")),
        "Askıya Alınacağı Tarih": format_date(subscription.get("holdUntil")),
        "Son Ödeme Tutarı": format_amount(
            subscription.get("amount"),
            subscription.get("currency")
        ),
        "error": ""
    }


def process_user(user):
    try:
        payload = fetch_detail(user["user_id"])
        return parse_user(user, payload)
    except Exception as e:
        return {
            "Email": user.get("email", ""),
            "User ID": user.get("user_id", ""),
            "Geçerlilik Tarihi": "",
            "Kapanış Tarihi": "",
            "Askıya Alınacağı Tarih": "",
            "Son Ödeme Tutarı": "",
            "error": str(e)
        }


def load_processed_ids() -> set:
    if not os.path.exists(CHECKPOINT_FILE):
        return set()

    try:
        old_df = pd.read_csv(CHECKPOINT_FILE, dtype=str)
        if "User ID" not in old_df.columns:
            return set()
        processed = set(old_df["User ID"].dropna().astype(str))
        print(f"Checkpoint bulundu. Daha önce işlenmiş kayıt sayısı: {len(processed)}")
        return processed
    except Exception as e:
        print(f"Checkpoint okunamadı: {e}")
        return set()


def append_to_checkpoint(rows: List[Dict[str, Any]]):
    if not rows:
        return

    df = pd.DataFrame(rows)

    file_exists = os.path.exists(CHECKPOINT_FILE)
    df.to_csv(
        CHECKPOINT_FILE,
        mode="a",
        header=not file_exists,
        index=False,
        encoding="utf-8-sig"
    )


def create_excel_from_checkpoint():
    if not os.path.exists(CHECKPOINT_FILE):
        print("Checkpoint dosyası bulunamadı, Excel oluşturulamadı.")
        return

    df = pd.read_csv(CHECKPOINT_FILE, dtype=str).fillna("")

    columns = [
        "Email",
        "User ID",
        "Geçerlilik Tarihi",
        "Kapanış Tarihi",
        "Askıya Alınacağı Tarih",
        "Son Ödeme Tutarı",
        "error"
    ]

    for col in columns:
        if col not in df.columns:
            df[col] = ""

    df = df[columns]

    with pd.ExcelWriter(OUTPUT_FILE, engine="openpyxl") as writer:
        df.to_excel(writer, index=False, sheet_name="Aktif Aboneler")
        ws = writer.sheets["Aktif Aboneler"]

        for col in ws.columns:
            max_len = max(len(str(cell.value or "")) for cell in col) + 2
            ws.column_dimensions[col[0].column_letter].width = max_len

    print(f"Bitti: {OUTPUT_FILE} ({len(df)} kayıt)")


def main():
    processed_ids = load_processed_ids()

    users = fetch_all_users()
    print("Toplam gelen user:", len(users))

    users = [u for u in users if str(u["user_id"]) not in processed_ids]
    print("İşlenecek kalan user:", len(users))

    if not users:
        print("Yeni işlenecek kullanıcı yok. Excel oluşturuluyor...")
        create_excel_from_checkpoint()
        return

    results_buffer = []
    completed = 0

    with ThreadPoolExecutor(max_workers=MAX_WORKERS) as executor:
        futures = [executor.submit(process_user, user) for user in users]

        for future in as_completed(futures):
            result = future.result()
            results_buffer.append(result)
            completed += 1

            if completed % 50 == 0 or completed == len(futures):
                print(f"{completed}/{len(futures)} işlendi")

            if len(results_buffer) >= FLUSH_EVERY:
                append_to_checkpoint(results_buffer)
                print(f"Checkpoint yazıldı: +{len(results_buffer)} kayıt")
                results_buffer = []

    if results_buffer:
        append_to_checkpoint(results_buffer)
        print(f"Son checkpoint yazıldı: +{len(results_buffer)} kayıt")

    create_excel_from_checkpoint()


if __name__ == "__main__":
    main()