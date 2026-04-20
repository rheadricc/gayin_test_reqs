"""
===============================
🚀 RUN COMMANDS (MAC)
===============================

cd ~/GAIN_API_QUERY/bo_profile_count/all_profiles

source venv/bin/activate

python bo_all_profiles_count.py
"""

import os
import asyncio
import json

import aiohttp
from dotenv import load_dotenv
from tqdm import tqdm

# =========================================================
# ENV
# =========================================================
ENV_PATH = os.path.join(os.path.dirname(__file__), ".env")
load_dotenv(ENV_PATH)

BASE_URL = os.getenv("PROD_BASE_URL", "").rstrip("/")
AUTH_TOKEN = os.getenv("AUTH_TOKEN", "")

PAGE_SIZE = int(os.getenv("PAGE_SIZE", "100"))
MAX_PAGES = int(os.getenv("MAX_PAGES", "0"))
CONCURRENT_REQUESTS = int(os.getenv("MAX_WORKERS", "35"))

PROFILE_CREATED_AFTER = os.getenv("PROFILE_CREATED_AFTER", "").strip()

PAUSE_EVERY_PAGES = int(os.getenv("PAUSE_EVERY_PAGES", "50"))
PAUSE_SECONDS = float(os.getenv("PAUSE_SECONDS", "10"))

MAX_RETRIES = int(os.getenv("MAX_RETRIES", "3"))

CHECKPOINT_FILE = "checkpoint_profiles.json"
FAILED_PAGES_FILE = "failed_pages_profiles.json"

LIST_URL = f"{BASE_URL}/CALL/User/getUserList/default"
DETAIL_URL_TMPL = f"{BASE_URL}/CALL/User/getUserDetailForBo/{{user_id}}"

HEADERS = {
    "Authorization": AUTH_TOKEN,
    "Content-Type": "application/json",
}

QUERY_ALL_USERS = "NOT status:DELETED"

# =========================================================
# CHECKPOINT HELPERS
# =========================================================
def load_checkpoint():
    try:
        with open(CHECKPOINT_FILE, "r", encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        return None
    except Exception as e:
        print(f"[CHECKPOINT LOAD ERROR] {type(e).__name__}: {e}")
        return None


def save_checkpoint(page, scanned, users_with_profiles, total_profiles, multi_profile_users, single_profile_users):
    data = {
        "last_page": page,
        "scanned": scanned,
        "users_with_profiles": users_with_profiles,
        "total_profiles": total_profiles,
        "multi_profile_users": multi_profile_users,
        "single_profile_users": single_profile_users,
    }
    with open(CHECKPOINT_FILE, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)


def load_failed_pages():
    try:
        with open(FAILED_PAGES_FILE, "r", encoding="utf-8") as f:
            data = json.load(f)
            if isinstance(data, list):
                return [int(x) for x in data]
            return []
    except FileNotFoundError:
        return []
    except Exception as e:
        print(f"[FAILED LOAD ERROR] {type(e).__name__}: {e}")
        return []


def save_failed_pages(pages):
    pages = sorted(set(int(p) for p in pages))
    with open(FAILED_PAGES_FILE, "w", encoding="utf-8") as f:
        json.dump(pages, f, ensure_ascii=False, indent=2)


# =========================================================
# LIST PAGE
# =========================================================
async def fetch_list_page(session, offset: int):
    body = {
        "query": QUERY_ALL_USERS,
        "from": offset,
        "pageSize": PAGE_SIZE,
        "sorts": [{"createdAt": "desc"}],
    }

    for attempt in range(MAX_RETRIES):
        try:
            async with session.post(LIST_URL, json=body, timeout=30) as resp:
                print(f"[LIST] offset={offset} status={resp.status}")

                text = await resp.text()

                if resp.status in (429, 500, 502, 503, 504):
                    sleep_s = min(10.0, 1.5 * (2 ** attempt))
                    print(f"[LIST RETRY] offset={offset} status={resp.status} sleep={sleep_s:.1f}s")
                    await asyncio.sleep(sleep_s)
                    continue

                resp.raise_for_status()

                try:
                    payload = json.loads(text)
                except json.JSONDecodeError:
                    print("[LIST ERROR] response JSON değil:")
                    print(text[:1500])
                    return None, None

                if isinstance(payload, dict):
                    print("[LIST PAYLOAD KEYS]", list(payload.keys()))
                else:
                    print("[LIST PAYLOAD TYPE]", type(payload))

                meta = payload.get("meta", {}) if isinstance(payload, dict) else {}

                users = []
                if isinstance(payload, dict):
                    users = (
                        payload.get("data")
                        or payload.get("items")
                        or payload.get("users")
                        or payload.get("result")
                        or (payload.get("payload") or {}).get("data")
                        or []
                    )

                print(f"[LIST USERS RAW COUNT] {len(users) if isinstance(users, list) else 'not_list'}")

                ids = []
                if isinstance(users, list):
                    for u in users:
                        if not isinstance(u, dict):
                            continue
                        for key in ("userId", "id", "uuid"):
                            value = u.get(key)
                            if isinstance(value, str) and value:
                                ids.append(value)
                                break

                print(f"[LIST IDS COUNT] {len(ids)}")

                if not ids:
                    print("[LIST EMPTY PAYLOAD SAMPLE]")
                    print(str(payload)[:1500])

                return ids, meta

        except Exception as e:
            sleep_s = min(10.0, 1.5 * (2 ** attempt))
            print(f"[LIST RETRY] offset={offset} err={type(e).__name__}: {e} sleep={sleep_s:.1f}s")
            await asyncio.sleep(sleep_s)

    return None, None


# =========================================================
# DETAIL PAGE
# =========================================================
async def fetch_user_profile_count(session, user_id: str) -> int:
    url = DETAIL_URL_TMPL.format(user_id=user_id)

    try:
        async with session.get(url, timeout=30) as resp:
            resp.raise_for_status()
            payload = await resp.json()

        profiles = payload.get("profiles", [])
        if not isinstance(profiles, list):
            return 0

        profile_ids = set()

        for p in profiles:
            if not isinstance(p, dict):
                continue

            profile_id = p.get("id")
            if not profile_id:
                continue

            if PROFILE_CREATED_AFTER:
                created_at = p.get("createdAt")
                if not created_at:
                    continue

                created_date = str(created_at)[:10]
                if created_date < PROFILE_CREATED_AFTER:
                    continue

            profile_ids.add(profile_id)

        return len(profile_ids)

    except Exception as e:
        print(f"[DETAIL FAIL] user_id={user_id} err={type(e).__name__}: {e}")
        return 0


# =========================================================
# PROCESS IDS
# =========================================================
async def process_ids(session, ids):
    scanned = 0
    users_with_profiles = 0
    total_profiles = 0
    multi_profile_users = 0
    single_profile_users = 0

    if not ids:
        return 0, 0, 0, 0, 0

    sem = asyncio.Semaphore(CONCURRENT_REQUESTS)

    async def bounded(uid):
        async with sem:
            return await fetch_user_profile_count(session, uid)

    tasks = [bounded(uid) for uid in ids]

    for coro in tqdm(asyncio.as_completed(tasks), total=len(tasks), leave=False):
        profile_count = await coro
        scanned += 1
        total_profiles += profile_count

        if profile_count > 0:
            users_with_profiles += 1

        if profile_count == 1:
            single_profile_users += 1
        elif profile_count > 1:
            multi_profile_users += 1

    return scanned, users_with_profiles, total_profiles, multi_profile_users, single_profile_users


# =========================================================
# MAIN
# =========================================================
async def main():
    if not BASE_URL:
        raise ValueError("PROD_BASE_URL boş. .env kontrol et.")
    if not AUTH_TOKEN:
        raise ValueError("AUTH_TOKEN boş. .env kontrol et.")

    timeout = aiohttp.ClientTimeout(total=30)
    connector = aiohttp.TCPConnector(limit=200, ttl_dns_cache=300, ssl=False)

    async with aiohttp.ClientSession(
        headers=HEADERS,
        timeout=timeout,
        connector=connector
    ) as session:

        checkpoint = load_checkpoint()

        start_page = 1
        scanned_total = 0
        users_with_profiles_total = 0
        profiles_total = 0
        multi_profile_users_total = 0
        single_profile_users_total = 0

        if checkpoint:
            start_page = int(checkpoint.get("last_page", 0)) + 1
            scanned_total = int(checkpoint.get("scanned", 0))
            users_with_profiles_total = int(checkpoint.get("users_with_profiles", 0))
            profiles_total = int(checkpoint.get("total_profiles", 0))
            multi_profile_users_total = int(checkpoint.get("multi_profile_users", 0))
            single_profile_users_total = int(checkpoint.get("single_profile_users", 0))

            print(
                f"[RESUME] start_page={start_page} "
                f"scanned={scanned_total} "
                f"users_with_profiles={users_with_profiles_total} "
                f"profiles={profiles_total} "
                f"multi={multi_profile_users_total} "
                f"single={single_profile_users_total}"
            )

        first_ids, meta = await fetch_list_page(session, 0)

        if first_ids is None:
            print("İlk liste sayfası alınamadı.")
            return

        if not first_ids:
            print("İlk sayfa boş geldi.")
            print("Meta:", meta)
            return

        total_pages = int((meta or {}).get("totalPage", 1))
        per_page = int((meta or {}).get("perPage", PAGE_SIZE))
        pages_to_scan = total_pages if MAX_PAGES == 0 else min(MAX_PAGES, total_pages)

        print(f"[START] total_pages={total_pages} per_page={per_page} pages_to_scan={pages_to_scan}")

        if start_page <= 1:
            s, u, p, m, sp = await process_ids(session, first_ids)
            scanned_total += s
            users_with_profiles_total += u
            profiles_total += p
            multi_profile_users_total += m
            single_profile_users_total += sp

            print(
                f"[PAGE 1] scanned={scanned_total} "
                f"users_with_profiles={users_with_profiles_total} "
                f"profiles={profiles_total} "
                f"multi={multi_profile_users_total} "
                f"single={single_profile_users_total}"
            )

            save_checkpoint(
                1,
                scanned_total,
                users_with_profiles_total,
                profiles_total,
                multi_profile_users_total,
                single_profile_users_total,
            )
            start_page = 2

        failed_pages = load_failed_pages()

        for page in range(start_page, pages_to_scan + 1):
            offset = (page - 1) * per_page
            ids, _meta = await fetch_list_page(session, offset)

            if ids is None or len(ids) == 0:
                print(f"[FAILED PAGE] page={page} offset={offset}")
                failed_pages.append(page)
                save_failed_pages(failed_pages)
                continue

            s, u, p, m, sp = await process_ids(session, ids)
            scanned_total += s
            users_with_profiles_total += u
            profiles_total += p
            multi_profile_users_total += m
            single_profile_users_total += sp

            print(
                f"[PAGE {page}] scanned={scanned_total} "
                f"users_with_profiles={users_with_profiles_total} "
                f"profiles={profiles_total} "
                f"multi={multi_profile_users_total} "
                f"single={single_profile_users_total}"
            )

            save_checkpoint(
                page,
                scanned_total,
                users_with_profiles_total,
                profiles_total,
                multi_profile_users_total,
                single_profile_users_total,
            )

            if PAUSE_EVERY_PAGES and page % PAUSE_EVERY_PAGES == 0:
                print(f"[PAUSE] {PAUSE_SECONDS}s")
                await asyncio.sleep(PAUSE_SECONDS)

        failed_pages = load_failed_pages()
        if failed_pages:
            print(f"[FAILED RETRY] total_failed_pages={len(failed_pages)}")
            still_failed = []

            for page in failed_pages:
                offset = (page - 1) * per_page
                ids, _meta = await fetch_list_page(session, offset)

                if ids is None or len(ids) == 0:
                    still_failed.append(page)
                    continue

                s, u, p, m, sp = await process_ids(session, ids)
                scanned_total += s
                users_with_profiles_total += u
                profiles_total += p
                multi_profile_users_total += m
                single_profile_users_total += sp

                print(
                    f"[RECOVERED PAGE {page}] scanned={scanned_total} "
                    f"users_with_profiles={users_with_profiles_total} "
                    f"profiles={profiles_total} "
                    f"multi={multi_profile_users_total} "
                    f"single={single_profile_users_total}"
                )

                save_checkpoint(
                    page,
                    scanned_total,
                    users_with_profiles_total,
                    profiles_total,
                    multi_profile_users_total,
                    single_profile_users_total,
                )

            save_failed_pages(still_failed)

        print("\n==== FINAL RESULT ====")
        print(f"Scanned Accounts (a): {scanned_total}")
        print(f"Accounts With At Least 1 Profile: {users_with_profiles_total}")
        print(f"Total Profiles (b): {profiles_total}")

        if scanned_total > 0:
            print(f"Avg Profiles Per Account (c): {profiles_total / scanned_total:.3f}")

        print(f"Multi Profile Users (d): {multi_profile_users_total}")
        print(f"Single Profile Users (e): {single_profile_users_total}")

        if users_with_profiles_total > 0:
            print(f"Avg Profiles Per Profiled User: {profiles_total / users_with_profiles_total:.3f}")


if __name__ == "__main__":
    asyncio.run(main())