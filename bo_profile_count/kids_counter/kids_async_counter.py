import os
import asyncio
import json
from typing import List, Tuple

import aiohttp
from dotenv import load_dotenv
from tqdm import tqdm

from google.cloud import bigquery
from datetime import datetime, timezone, timedelta
import uuid

BQ_TABLE = "microgain-9f959.bc_t.active_subscribers_snapshot"

def write_snapshot_to_bq(active_total: int, kids_total: int, source: str = "backoffice_api"):
    client = bigquery.Client()
    row = {
        "snapshot_ts": datetime.now(timezone.utc).isoformat(),
        "active_total": int(active_total) if active_total is not None else None,
        "kids_total": int(kids_total),
        "source": source,
        "run_id": str(uuid.uuid4()),
    }
    errors = client.insert_rows_json(BQ_TABLE, [row])
    if errors:
        raise RuntimeError(f"BigQuery insert error: {errors}")
    print("[BQ] Insert OK:", row)
    

RESULT_FILE = "last_run_result.json"

def clear_run_state():
    for f in (CHECKPOINT_FILE, FAILED_PAGES_FILE):
        try:
            os.remove(f)
        except FileNotFoundError:
            pass
        
def save_final_result(active_total, scanned_total, kids_total):
    data = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "active_total": active_total,
        "scanned_total": scanned_total,
        "kids_total": kids_total,
    }
    with open(RESULT_FILE, "w") as f:
        json.dump(data, f, indent=2)

    print("[RESULT FILE WRITTEN]", RESULT_FILE)


load_dotenv()

CHECKPOINT_FILE = "checkpoint.json"
FAILED_PAGES_FILE = "failed_pages.json"

LIST_MAX_RETRIES = 4           # list için 4 deneme
LIST_BASE_BACKOFF = 1.5        # 1.5s, 3s, 6s, 10s (cap ile)
LIST_BACKOFF_CAP = 10.0        # max 10s
LIST_FAIL_COOLDOWN = 10.0      # list fail olunca sayfa geçmeden önce 10s dinlen
FAILED_RETRY_ROUNDS = 2        # en sonda failed'ları kaç tur döneceğiz
FAILED_ROUND_COOLDOWN = 30.0   # failed turu arası bekleme

BASE_URL = os.getenv("PROD_BASE_URL", "").rstrip("/")
AUTH_TOKEN = os.getenv("AUTH_TOKEN", "")

PAGE_SIZE = int(os.getenv("PAGE_SIZE", "100"))
MAX_PAGES = int(os.getenv("MAX_PAGES", "0"))

CONCURRENT_REQUESTS = int(os.getenv("MAX_WORKERS", "100"))

PAUSE_EVERY_PAGES = int(os.getenv("PAUSE_EVERY_PAGES", "50"))
PAUSE_SECONDS = float(os.getenv("PAUSE_SECONDS", "10"))

LIST_URL = f"{BASE_URL}/CALL/User/getUserList/default"
DETAIL_URL_TMPL = f"{BASE_URL}/CALL/User/getUserDetailForBo/{{user_id}}"

HEADERS = {
    "Authorization": AUTH_TOKEN,
    "Content-Type": "application/json",
}

SCAN_MODE = os.getenv("SCAN_MODE", "full").lower()
DATE_FIELD = os.getenv("DATE_FIELD", "updatedAt")
LOOKBACK_DAYS = int(os.getenv("LOOKBACK_DAYS", "2"))

def to_epoch_ms(dt: datetime) -> int:
    return int(dt.timestamp() * 1000)

def build_query():
    base_query = (
        "NOT status:DELETED AND "
        "(subscription.status:active OR subscription.status:in_grace OR subscription.status:on_hold)"
)

    if SCAN_MODE == "incremental":
        end_dt = datetime.now(timezone.utc)
        start_dt = end_dt - timedelta(days=LOOKBACK_DAYS)

        start_ms = to_epoch_ms(start_dt)
        end_ms = to_epoch_ms(end_dt)

        return f"{base_query} AND {DATE_FIELD}:[{start_ms} TO {end_ms}]"

    return base_query

QUERY_ACTIVE = build_query()
print(f"[QUERY] {QUERY_ACTIVE}")

def load_checkpoint():
    try:
        with open(CHECKPOINT_FILE, "r") as f:
            return json.load(f)
    except FileNotFoundError:
        return None

def save_checkpoint(page: int, scanned: int, kids: int):
    with open(CHECKPOINT_FILE, "w") as f:
        json.dump(
            {"last_page": page, "scanned_users": scanned, "kids_users": kids},
            f
        )

def load_failed_pages() -> list[int]:
    try:
        with open(FAILED_PAGES_FILE, "r") as f:
            data = json.load(f)
            if isinstance(data, list):
                return [int(x) for x in data]
    except FileNotFoundError:
        pass
    return []

def save_failed_pages(pages: list[int]) -> None:
    # unique + sıralı
    pages = sorted(set(int(p) for p in pages))
    with open(FAILED_PAGES_FILE, "w") as f:
        json.dump(pages, f)

async def fetch_list_page(session, offset: int):

    sort_field = DATE_FIELD if SCAN_MODE == "incremental" else "createdAt"

    body = {
        "query": QUERY_ACTIVE,
        "from": offset,
        "pageSize": PAGE_SIZE,
        "sorts": [{sort_field: "desc"}],
    }

    last_status = None
    for attempt in range(LIST_MAX_RETRIES):
        try:
            async with session.post(LIST_URL, json=body, timeout=30) as resp:
                last_status = resp.status

                if resp.status in (429, 500, 502, 503, 504):
                    sleep_s = min(LIST_BACKOFF_CAP, LIST_BASE_BACKOFF * (2 ** attempt))
                    print(f"[LIST RETRY] offset={offset} status={resp.status} sleep={sleep_s:.1f}s")
                    await asyncio.sleep(sleep_s)
                    continue

                resp.raise_for_status()
                payload = await resp.json()

                meta = payload.get("meta", {}) or {}
                users = (
                    payload.get("data")
                    or payload.get("items")
                    or payload.get("users")
                    or payload.get("result")
                    or (payload.get("payload") or {}).get("data")
                    or []
)


                ids = []
                for u in users:
                    if not isinstance(u, dict):
                        continue
                    for key in ("userId", "id", "uuid"):
                        v = u.get(key)
                        if isinstance(v, str) and v:
                            ids.append(v)
                            break
                # 200 dönüp boş liste gelmesi de pratikte "fail" sayılmalı
                if not ids:
                    return None, meta
                
                return ids, meta

        except Exception as e:
            # network / timeout vb.
            sleep_s = min(LIST_BACKOFF_CAP, LIST_BASE_BACKOFF * (2 ** attempt))
            print(f"[LIST RETRY] offset={offset} err={type(e).__name__} sleep={sleep_s:.1f}s")
            await asyncio.sleep(sleep_s)

    print(f"[LIST FAIL] offset={offset} status={last_status}")
    return None, None

async def fetch_user_has_kid(session, user_id: str) -> bool:
    url = DETAIL_URL_TMPL.format(user_id=user_id)

    try:
        async with session.get(url) as resp:
            resp.raise_for_status()
            payload = await resp.json()

        profiles = payload.get("profiles", [])
        return any(p.get("profileType") == "KID" for p in profiles)

    except:
        return False


async def process_ids(session, ids: List[str]) -> Tuple[int, int]:
    kids = 0
    scanned = 0

    if not ids:
        return 0, 0

    sem = asyncio.Semaphore(CONCURRENT_REQUESTS)

    async def bounded(uid):
        async with sem:
            return await fetch_user_has_kid(session, uid)

    tasks = [bounded(uid) for uid in ids]

    for coro in tqdm(asyncio.as_completed(tasks), total=len(tasks), leave=False):
        result = await coro
        scanned += 1
        if result:
            kids += 1

    return scanned, kids


async def main():

    timeout = aiohttp.ClientTimeout(total=15)

    connector = aiohttp.TCPConnector(
        limit=200,
        ttl_dns_cache=300,
        ssl=False,
    )

    async with aiohttp.ClientSession(
        headers=HEADERS,
        timeout=timeout,
        connector=connector
    ) as session:
        checkpoint = load_checkpoint()
        start_page = 1
        scanned_total = 0
        kids_total = 0

        if checkpoint:
            start_page = int(checkpoint.get("last_page", 0)) + 1
            scanned_total = int(checkpoint.get("scanned_users", 0))
            kids_total = int(checkpoint.get("kids_users", 0))
            print(f"[RESUME] page={start_page} (last={checkpoint.get('last_page')}) scanned={scanned_total} kids={kids_total}")


        first_ids, meta = await fetch_list_page(session, 0)

        if meta is None:
            raise RuntimeError("List endpoint fail: meta alınamadı. Script durduruldu.")

        active_total = meta.get("total")


        total_pages = meta.get("totalPage", 1)
        per_page = int(meta.get("perPage", PAGE_SIZE))
        pages_to_scan = total_pages if MAX_PAGES == 0 else min(MAX_PAGES, total_pages)



        # Page 1# Page 1 (resume değilsek)
        if start_page <= 1:
            s, k = await process_ids(session, first_ids)
            scanned_total += s
            kids_total += k
            print(f"[progress] page=1 scanned={scanned_total} kids={kids_total}")
            save_checkpoint(1, scanned_total, kids_total)
            start_page = 2

        failed_pages = load_failed_pages()
        if start_page <= pages_to_scan:

            for page in range(start_page, pages_to_scan + 1):

                offset = (page - 1) * per_page

                ids, _meta = await fetch_list_page(session, offset)
                if not ids:
                    failed_pages.append(page)
                    save_failed_pages(failed_pages)
                    print(f"[SKIP] page={page} offset={offset} (empty/failed) cooldown=10s")
                    await asyncio.sleep(10)
                    continue

                s, k = await process_ids(session, ids)
                scanned_total += s
                kids_total += k

                print(f"[progress] page={page} scanned={scanned_total} kids={kids_total}")
                save_checkpoint(page, scanned_total, kids_total)

                if PAUSE_EVERY_PAGES and page % PAUSE_EVERY_PAGES == 0:
                    print(f"\n[PAUSE] {PAUSE_SECONDS} saniye...\n")
                    await asyncio.sleep(PAUSE_SECONDS)

        else:
            print("[SCAN ALREADY COMPLETE — SKIPPING MAIN SCAN]")
    
        failed_pages = load_failed_pages()
        if failed_pages:
            print(f"\n[FAILED QUEUE] {len(failed_pages)} page tekrar denenecek.")

        for round_no in range(1, FAILED_RETRY_ROUNDS + 1):
            failed_pages = load_failed_pages()
            if not failed_pages:
                break

            print(f"\n[FAILED ROUND {round_no}/{FAILED_RETRY_ROUNDS}] pages={len(failed_pages)}")
            still_failed = []

            for page in failed_pages:
                offset = (page - 1) * per_page
                ids, _meta = await fetch_list_page(session, offset)

                if ids is None:
                    still_failed.append(page)
                    continue

                s, k = await process_ids(session, ids)
                scanned_total += s
                kids_total += k

                print(f"[recovered] page={page} scanned={scanned_total} kids={kids_total}")
                save_checkpoint(page, scanned_total, kids_total)

            save_failed_pages(still_failed)

            if still_failed:
                print(f"[FAILED ROUND {round_no}] kalan={len(still_failed)} cooldown={FAILED_ROUND_COOLDOWN:.0f}s")
                await asyncio.sleep(FAILED_ROUND_COOLDOWN)
                
        # en son rapor

    print("\n==== RESULT ====")
    print(f"Active subscribers: {active_total}")
    print(f"Scanned users: {scanned_total}")
    print(f"Users with KID profile: {kids_total}")
    
    save_final_result(active_total, scanned_total, kids_total)
    write_snapshot_to_bq(active_total, kids_total)

    clear_run_state()

    print("\nRUN STATE RESET — READY FOR NEXT EXECUTION")


if __name__ == "__main__":
    asyncio.run(main())