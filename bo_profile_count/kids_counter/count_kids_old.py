import os
import time
import json
import threading
from typing import List, Tuple, Dict, Any
from concurrent.futures import ThreadPoolExecutor, wait, FIRST_COMPLETED
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

import requests
from dotenv import load_dotenv
from tqdm import tqdm

# ================= CONFIG =================

CHECKPOINT_FILE = "checkpoint.json"
_thread_local = threading.local()

load_dotenv()

BASE_URL = os.getenv("PROD_BASE_URL", "").rstrip("/")
AUTH_TOKEN = os.getenv("AUTH_TOKEN", "")

PAGE_SIZE = int(os.getenv("PAGE_SIZE", "100"))
MAX_PAGES = int(os.getenv("MAX_PAGES", "0"))

PAUSE_EVERY_PAGES = int(os.getenv("PAUSE_EVERY_PAGES", "50"))
PAUSE_SECONDS = float(os.getenv("PAUSE_SECONDS", "10"))

MAX_WORKERS = int(os.getenv("MAX_WORKERS", "30"))
IN_FLIGHT = int(os.getenv("IN_FLIGHT", "30"))

if not BASE_URL or not AUTH_TOKEN:
    raise SystemExit("PROD_BASE_URL ve AUTH_TOKEN .env içinde olmalı.")

LIST_URL = f"{BASE_URL}/CALL/User/getUserList/default"
DETAIL_URL_TMPL = f"{BASE_URL}/CALL/User/getUserDetailForBo/{{user_id}}"

HEADERS = {
    "Authorization": AUTH_TOKEN,
    "Content-Type": "application/json",
}

QUERY_ACTIVE = "NOT status:DELETED AND subscription.status:active"

# ===========================================


def get_session() -> requests.Session:
    if not hasattr(_thread_local, "session"):
        s = requests.Session()

        adapter = HTTPAdapter(
            pool_connections=100,
            pool_maxsize=100,
            max_retries=Retry(total=0)
        )

        s.mount("https://", adapter)
        s.mount("http://", adapter)

        s.headers.update(HEADERS)
        _thread_local.session = s

    return _thread_local.session


def save_checkpoint(page: int, scanned: int, kids: int):
    with open(CHECKPOINT_FILE, "w") as f:
        json.dump({
            "last_page": page,
            "scanned_users": scanned,
            "kids_users": kids
        }, f)


def load_checkpoint():
    try:
        with open(CHECKPOINT_FILE, "r") as f:
            return json.load(f)
    except:
        return None


def fetch_list_page(offset: int) -> Tuple[List[str], Dict[str, Any]]:
    body = {
        "query": QUERY_ACTIVE,
        "from": offset,
        "pageSize": PAGE_SIZE,
        "sorts": [{"createdAt": "desc"}],
    }

    r = requests.post(LIST_URL, json=body, headers=HEADERS, timeout=(5, 30))
    r.raise_for_status()
    payload = r.json()

    meta = payload.get("meta", {})

    users = (
        payload.get("data")
        or payload.get("items")
        or payload.get("users")
        or payload.get("result")
        or []
    )

    ids = []
    for u in users:
        for key in ("userId", "id", "uuid"):
            if key in u and u[key]:
                ids.append(u[key])
                break

    if not ids:
        print(f"[DEBUG] offset={offset} -> USER LIST EMPTY")

    return ids, meta


def fetch_user_has_kid(user_id: str) -> bool:
    sess = get_session()
    url = DETAIL_URL_TMPL.format(user_id=user_id)

    try:
        r = sess.get(url, timeout=(1.5, 4))
        r.raise_for_status()
        payload = r.json()

        profiles = payload.get("profiles", [])
        return any(
            isinstance(p, dict) and p.get("profileType") == "KID"
            for p in profiles
        )

    except:
        return False


def process_ids_parallel(ids: List[str], desc: str) -> Tuple[int, int]:
    scanned = 0
    kids = 0

    if not ids:
        return 0, 0

    with ThreadPoolExecutor(max_workers=MAX_WORKERS) as executor:
        in_flight = set()
        it = iter(ids)

        for _ in range(min(IN_FLIGHT, len(ids))):
            uid = next(it, None)
            if uid:
                in_flight.add(executor.submit(fetch_user_has_kid, uid))

        pbar = tqdm(total=len(ids), desc=desc, leave=False)

        while in_flight:
            done, in_flight = wait(in_flight, return_when=FIRST_COMPLETED)

            for fut in done:
                scanned += 1
                try:
                    if fut.result():
                        kids += 1
                except:
                    pass

                pbar.update(1)

                uid = next(it, None)
                if uid:
                    in_flight.add(executor.submit(fetch_user_has_kid, uid))

        pbar.close()

    return scanned, kids


def main():

    print(f"MAX_WORKERS={MAX_WORKERS} PAGE_SIZE={PAGE_SIZE}")

    checkpoint = load_checkpoint()
    start_page = 1
    scanned_users = 0
    kids_users = 0

    if checkpoint:
        print(f"[RESUME] Page {checkpoint['last_page']} sonrası devam...")
        start_page = checkpoint["last_page"] + 1
        scanned_users = checkpoint["scanned_users"]
        kids_users = checkpoint["kids_users"]

    first_ids, meta = fetch_list_page(0)

    total_active = meta.get("total")
    total_pages = meta.get("totalPage", 1)
    per_page = int(meta.get("perPage", PAGE_SIZE))

    pages_to_scan = total_pages if MAX_PAGES == 0 else min(MAX_PAGES, total_pages)

    if start_page <= 1:
        s, k = process_ids_parallel(first_ids, "Users (page 1)")
        scanned_users += s
        kids_users += k
        save_checkpoint(1, scanned_users, kids_users)
        start_page = 2

    for page in range(start_page, pages_to_scan + 1):

        offset = (page - 1) * per_page
        ids, _ = fetch_list_page(offset)

        s, k = process_ids_parallel(ids, f"Users (page {page}/{pages_to_scan})")
        scanned_users += s
        kids_users += k

        print(f"[progress] page={page} scanned={scanned_users} kids={kids_users}")
        save_checkpoint(page, scanned_users, kids_users)

        if PAUSE_EVERY_PAGES and page % PAUSE_EVERY_PAGES == 0:
            print(f"\n[PAUSE] {PAUSE_SECONDS} saniye bekleniyor...\n")
            time.sleep(PAUSE_SECONDS)

    print("\n==== RESULT ====")
    print(f"Active subscribers: {total_active}")
    print(f"Scanned users: {scanned_users}")
    print(f"Users with KID profile: {kids_users}")

    if total_active:
        print(f"Kids ratio: {kids_users / total_active:.4%}")


if __name__ == "__main__":
    main()
