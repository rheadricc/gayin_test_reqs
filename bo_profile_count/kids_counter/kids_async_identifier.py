import os
import asyncio
import json
from typing import Any, Dict, List, Optional

import aiohttp
from dotenv import load_dotenv
from tqdm import tqdm

from google.cloud import bigquery
from datetime import datetime, timezone, timedelta
import uuid
import logging

import boto3
from botocore.exceptions import ClientError

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s | %(levelname)s | %(name)s | %(message)s"
)

logger = logging.getLogger("kids_async_identifier")

USER_STATE_TABLE = "microgain-9f959.bc_t.user_kids_profile_state"
USER_STATE_STAGING_TABLE = "microgain-9f959.bc_t.user_kids_profile_state_staging"
BQ_TABLE = "microgain-9f959.bc_t.active_subscribers_snapshot"

def write_user_states_to_bq(user_states: list[dict]):
    if not user_states:
        logger.info("[BQ] No user states to write.")
        return

    client = bigquery.Client()

    run_id = str(uuid.uuid4())
    checked_at = datetime.now(timezone.utc).isoformat()

    rows = []
    for row in user_states:
        if not row.get("user_id"):
            continue

        rows.append({
            "user_id": row["user_id"],
            "subscription_status": row["subscription_status"],
            "has_kid_profile": row["has_kid_profile"],
            "total_profiles": row["total_profiles"],
            "kid_profile_count": row["kid_profile_count"],
            "user_created_at": row["user_created_at"],
            "user_updated_at": row["user_updated_at"],
            "checked_at": checked_at,
            "run_id": run_id,
        })

    if not rows:
        logger.info("[BQ] No valid user states to write.")
        return

    # BigQuery MERGE aynı user_id için source tarafta birden fazla satır gelirse patlar.
    # BO list/detail akışında retry, resume veya liste endpoint davranışı nedeniyle aynı user_id birden fazla kez dönebilir.
    # Bu yüzden staging'e yüklemeden önce user_id bazında tekilleştiriyoruz.
    deduped_rows = {}
    for row in rows:
        deduped_rows[row["user_id"]] = row

    if len(deduped_rows) != len(rows):
        logger.warning(
            "[BQ DEDUPE] rows=%s unique_user_rows=%s duplicate_rows=%s",
            len(rows),
            len(deduped_rows),
            len(rows) - len(deduped_rows),
        )

    rows = list(deduped_rows.values())

    job_config = bigquery.LoadJobConfig(
        write_disposition=bigquery.WriteDisposition.WRITE_TRUNCATE,
        schema=[
            bigquery.SchemaField("user_id", "STRING"),
            bigquery.SchemaField("subscription_status", "STRING"),
            bigquery.SchemaField("has_kid_profile", "BOOL"),
            bigquery.SchemaField("total_profiles", "INT64"),
            bigquery.SchemaField("kid_profile_count", "INT64"),
            bigquery.SchemaField("user_created_at", "TIMESTAMP"),
            bigquery.SchemaField("user_updated_at", "TIMESTAMP"),
            bigquery.SchemaField("checked_at", "TIMESTAMP"),
            bigquery.SchemaField("run_id", "STRING"),
        ],
    )

    load_job = client.load_table_from_json(
        rows,
        USER_STATE_STAGING_TABLE,
        job_config=job_config
    )
    load_job.result()

    logger.info("[BQ STAGING LOAD] %s rows", len(rows))

    merge_sql = f"""
    MERGE `{USER_STATE_TABLE}` T
    USING (
      SELECT * EXCEPT(rn)
      FROM (
        SELECT
          S.*,
          ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY checked_at DESC) AS rn
        FROM `{USER_STATE_STAGING_TABLE}` S
        WHERE user_id IS NOT NULL
      )
      WHERE rn = 1
    ) S
    ON T.user_id = S.user_id

    WHEN MATCHED THEN UPDATE SET
      subscription_status = S.subscription_status,
      has_kid_profile = S.has_kid_profile,
      total_profiles = S.total_profiles,
      kid_profile_count = S.kid_profile_count,
      user_created_at = S.user_created_at,
      user_updated_at = S.user_updated_at,
      checked_at = S.checked_at,
      run_id = S.run_id

    WHEN NOT MATCHED THEN INSERT (
      user_id,
      subscription_status,
      has_kid_profile,
      total_profiles,
      kid_profile_count,
      user_created_at,
      user_updated_at,
      checked_at,
      run_id
    )
    VALUES (
      S.user_id,
      S.subscription_status,
      S.has_kid_profile,
      S.total_profiles,
      S.kid_profile_count,
      S.user_created_at,
      S.user_updated_at,
      S.checked_at,
      S.run_id
    )
    """

    merge_job = client.query(merge_sql)
    merge_job.result()

    logger.info("[BQ USER STATE MERGE] %s rows merged", len(rows))

def write_snapshot_to_bq(source: str = "backoffice_api"):
    client = bigquery.Client()

    summary_sql = f"""
    SELECT
      COUNT(*) AS active_total,
      COUNTIF(has_kid_profile) AS kids_total
    FROM `{USER_STATE_TABLE}`
    WHERE subscription_status IN ('ACTIVE', 'IN_GRACE', 'ON_HOLD')
    """

    result = list(client.query(summary_sql).result())[0]

    row = {
        "snapshot_ts": datetime.now(timezone.utc).isoformat(),
        "active_total": int(result.active_total),
        "kids_total": int(result.kids_total),
        "source": source,
        "run_id": str(uuid.uuid4()),
    }

    errors = client.insert_rows_json(BQ_TABLE, [row])
    if errors:
        raise RuntimeError(f"BigQuery insert error: {errors}")

    logger.info("[BQ SNAPSHOT INSERT] %s", row)

RESULT_FILE = "last_run_result.json"

def clear_run_state():
    for f in (CHECKPOINT_FILE, FAILED_PAGES_FILE):
        try:
            os.remove(f)
        except FileNotFoundError:
            pass
        
def save_final_result(active_total, scanned_total, kids_total, state_rows, run_started_at, run_finished_at):
    duration_seconds = (run_finished_at - run_started_at).total_seconds()

    data = {
        "run_started_at": run_started_at.isoformat(),
        "run_finished_at": run_finished_at.isoformat(),
        "duration_seconds": duration_seconds,
        "duration_minutes": round(duration_seconds / 60, 2),
        "active_total": active_total,
        "scanned_total": scanned_total,
        "kids_total": kids_total,
        "state_rows": state_rows,
        "scan_mode": SCAN_MODE,
        "max_pages": MAX_PAGES,
        "page_size": PAGE_SIZE,
        "max_workers": CONCURRENT_REQUESTS,
    }

    with open(RESULT_FILE, "w") as f:
        json.dump(data, f, indent=2)

    logger.info("[RESULT FILE WRITTEN] %s", RESULT_FILE)


load_dotenv()

CHECKPOINT_FILE = "checkpoint.json"
FAILED_PAGES_FILE = "failed_pages.json"

LIST_MAX_RETRIES = 4           # list için 4 deneme
LIST_BASE_BACKOFF = 1.5        # 1.5s, 3s, 6s, 10s (cap ile)
LIST_BACKOFF_CAP = 10.0        # max 10s
LIST_FAIL_COOLDOWN = 10.0      # list fail olunca sayfa geçmeden önce 10s dinlen
FAILED_RETRY_ROUNDS = 5        # en sonda failed'ları kaç tur döneceğiz
FAILED_ROUND_COOLDOWN = 60.0   # failed turu arası bekleme

BASE_URL = os.getenv("PROD_BASE_URL", "https://api.gain.tv/2da7kf8jf").rstrip("/")
AUTH_TOKEN = os.getenv("AUTH_TOKEN", "").strip()

# Prod MWAA: S3 token store kullanır.
# Lokal test: TOKEN_STORE_MODE=local verilirse aynı JSON formatını lokal dosyadan okur/yazar.
TOKEN_STORE_MODE = os.getenv("TOKEN_STORE_MODE", "s3").strip().lower()

S3_BUCKET = os.getenv("S3_BUCKET", "gain-data-airflow-bucket").strip()
S3_TOKEN_KEY = os.getenv("S3_TOKEN_KEY", "airflow_keys/token_store.json").strip()

LOCAL_TOKEN_STORE_PATH = os.getenv("LOCAL_TOKEN_STORE_PATH", "token_store.json").strip()

REFRESH_URL = os.getenv(
    "REFRESH_URL",
    "https://api.gain.tv/2da7kf8jf/TOKEN/refresh?__culture=tr-tr"
).strip()

PAGE_SIZE = int(os.getenv("PAGE_SIZE", "100"))
MAX_PAGES = int(os.getenv("MAX_PAGES", "0"))

CONCURRENT_REQUESTS = int(os.getenv("MAX_WORKERS", "100"))

PAUSE_EVERY_PAGES = int(os.getenv("PAUSE_EVERY_PAGES", "50"))
PAUSE_SECONDS = float(os.getenv("PAUSE_SECONDS", "10"))
ENABLE_TQDM = os.getenv("ENABLE_TQDM", "0") == "1"


LIST_URL = f"{BASE_URL}/CALL/User/getUserList/default"
DETAIL_URL_TMPL = f"{BASE_URL}/CALL/User/getUserDetailForBo/{{user_id}}"


def normalize_bearer_token(token: str) -> str:
    token = (token or "").strip()
    if not token:
        return ""
    return token if token.lower().startswith("bearer ") else f"Bearer {token}"


def get_access_token_from_store_payload(tokens: Dict[str, Any]) -> str:
    return (
        tokens.get("accessToken")
        or tokens.get("access_token")
        or tokens.get("token")
        or tokens.get("jwt")
        or ""
    )


def get_refresh_token_from_store_payload(tokens: Dict[str, Any]) -> str:
    return (
        tokens.get("refreshToken")
        or tokens.get("refresh_token")
        or tokens.get("refresh")
        or ""
    )


def load_tokens() -> Dict[str, Any]:
    if TOKEN_STORE_MODE == "local":
        try:
            with open(LOCAL_TOKEN_STORE_PATH, "r") as f:
                return json.load(f)
        except FileNotFoundError:
            logger.warning("[AUTH] Lokal token store bulunamadı: %s", LOCAL_TOKEN_STORE_PATH)
            return {
                "accessToken": AUTH_TOKEN,
                "refreshToken": "",
            }

    s3_client = boto3.client("s3")

    try:
        response = s3_client.get_object(
            Bucket=S3_BUCKET,
            Key=S3_TOKEN_KEY,
        )
        return json.loads(response["Body"].read().decode("utf-8"))

    except ClientError as e:
        if e.response.get("Error", {}).get("Code") == "NoSuchKey":
            logger.warning(
                "[AUTH] S3 token store bulunamadı: s3://%s/%s",
                S3_BUCKET,
                S3_TOKEN_KEY,
            )
            return {
                "accessToken": AUTH_TOKEN,
                "refreshToken": "",
            }

        raise


def save_tokens(tokens: Dict[str, Any]) -> None:
    payload = {
        "accessToken": get_access_token_from_store_payload(tokens),
        "refreshToken": get_refresh_token_from_store_payload(tokens),
    }

    if TOKEN_STORE_MODE == "local":
        with open(LOCAL_TOKEN_STORE_PATH, "w") as f:
            json.dump(payload, f, indent=2)

        logger.info("[AUTH] Lokal token store güncellendi: %s", LOCAL_TOKEN_STORE_PATH)
        return

    s3_client = boto3.client("s3")
    s3_client.put_object(
        Bucket=S3_BUCKET,
        Key=S3_TOKEN_KEY,
        Body=json.dumps(payload),
        ContentType="application/json",
    )

    logger.info(
        "[AUTH] S3 token store güncellendi: s3://%s/%s",
        S3_BUCKET,
        S3_TOKEN_KEY,
    )


def build_auth_headers() -> Dict[str, str]:
    return {
        "Authorization": normalize_bearer_token(AUTH_TOKEN),
        "Content-Type": "application/json",
        "User-Agent": "Python/aiohttp",
    }


async def refresh_access_token(session: aiohttp.ClientSession) -> Optional[str]:
    tokens = load_tokens()
    refresh_token = get_refresh_token_from_store_payload(tokens)

    if not refresh_token:
        logger.warning("[AUTH] Refresh token bulunamadı. Refresh adımı atlanıyor.")
        return None

    headers = {
        "Content-Type": "application/json",
    }

    body = {
        "refreshToken": refresh_token,
    }

    async with session.post(
        REFRESH_URL,
        headers=headers,
        json=body,
        timeout=30,
    ) as resp:
        if resp.status != 200:
            response_text = await resp.text()
            logger.warning(
                "[AUTH] Refresh token başarısız status=%s body=%s",
                resp.status,
                response_text[:500],
            )
            return None

        new_tokens = await resp.json()

    new_access_token = get_access_token_from_store_payload(new_tokens)
    new_refresh_token = get_refresh_token_from_store_payload(new_tokens)

    if not new_access_token:
        logger.warning("[AUTH] Refresh response içinde access token bulunamadı.")
        return None

    save_tokens({
        "accessToken": new_access_token,
        "refreshToken": new_refresh_token or refresh_token,
    })

    logger.info("[AUTH] Token refresh ile yenilendi.")
    return new_access_token

async def ensure_auth_token(session: aiohttp.ClientSession, force: bool = False) -> bool:
    global AUTH_TOKEN

    # Normal akışta her request öncesi S3/local token_store okumayalım.
    # İlk run başında AUTH_TOKEN set edilir; 401 gelirse force=True ile refresh denenir.
    if AUTH_TOKEN and not force:
        return True

    tokens = load_tokens()
    store_access_token = get_access_token_from_store_payload(tokens)
    store_refresh_token = get_refresh_token_from_store_payload(tokens)

    # Normal çalışma:
    # token_store.json içindeki mevcut accessToken direkt kullanılır.
    if store_access_token and not force:
        AUTH_TOKEN = normalize_bearer_token(store_access_token)
        return True

    # 401 veya boş accessToken durumunda:
    # Prod_Gain_BO_Promotion_Data_To_Bq_Script.py ile aynı mantıkta refresh denenir.
    if store_refresh_token:
        refreshed_token = await refresh_access_token(session)
        if refreshed_token:
            AUTH_TOKEN = normalize_bearer_token(refreshed_token)
            return True

    # Refresh token yoksa veya refresh başarısızsa:
    # eldeki accessToken son kez kullanılır.
    if store_access_token:
        AUTH_TOKEN = normalize_bearer_token(store_access_token)
        return True

    logger.warning("[AUTH] Kullanılabilir accessToken bulunamadı. token_store.json kontrol edilmeli.")
    return False

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
logger.info("[QUERY] %s", QUERY_ACTIVE)

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
            if not await ensure_auth_token(session):
                raise RuntimeError("Auth token alınamadı. token_store.json içeriği kontrol edilmeli.")

            async with session.post(LIST_URL, json=body, timeout=30, headers=build_auth_headers()) as resp:
                last_status = resp.status

                if resp.status == 401 and await ensure_auth_token(session, force=True):
                    logger.warning("[LIST RETRY] offset=%s status=401 token refreshed", offset)
                    continue

                if resp.status in (429, 500, 502, 503, 504):
                    sleep_s = min(LIST_BACKOFF_CAP, LIST_BASE_BACKOFF * (2 ** attempt))
                    logger.warning(
                        "[LIST RETRY] offset=%s status=%s sleep=%.1fs",
                        offset,
                        resp.status,
                        sleep_s
                    )
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
            logger.warning(
                    "[LIST RETRY] offset=%s err=%s sleep=%.1fs",
                    offset,
                    type(e).__name__,
                    sleep_s
                )
            await asyncio.sleep(sleep_s)

    logger.error("[LIST FAIL] offset=%s status=%s", offset, last_status)
    return None, None

async def fetch_user_state(session, user_id: str):
    url = DETAIL_URL_TMPL.format(user_id=user_id)

    try:
        if not await ensure_auth_token(session):
            raise RuntimeError("Auth token alınamadı. token_store.json içeriği kontrol edilmeli.")

        async with session.get(url, headers=build_auth_headers()) as resp:
            if resp.status == 401 and await ensure_auth_token(session, force=True):
                logger.warning("[DETAIL RETRY] user_id=%s status=401 token refreshed", user_id)
                async with session.get(url, headers=build_auth_headers()) as retry_resp:
                    retry_resp.raise_for_status()
                    payload = await retry_resp.json()
            else:
                resp.raise_for_status()
                payload = await resp.json()

        profiles = payload.get("profiles", []) or []

        kid_profiles = [
            p for p in profiles
            if p.get("profileType") == "KID" or p.get("isKidProfile") is True
        ]

        return {
            "user_id": payload.get("userId"),
            "subscription_status": payload.get("subscriptionStatus")
                                   or (payload.get("subscription") or {}).get("status"),
            "has_kid_profile": len(kid_profiles) > 0,
            "total_profiles": len(profiles),
            "kid_profile_count": len(kid_profiles),
            "user_created_at": payload.get("createdAt"),
            "user_updated_at": payload.get("updatedAt"),
        }

    except Exception as e:
        logger.exception(f"[DETAIL FAIL] {user_id}: {type(e).__name__}")
        return None

async def process_ids(session, ids: List[str]) -> Tuple[int, int, List[dict]]:
    kids = 0
    scanned = 0
    user_states = []

    if not ids:
        return 0, 0, []

    sem = asyncio.Semaphore(CONCURRENT_REQUESTS)

    async def bounded(uid):
        async with sem:
            return await fetch_user_state(session, uid)

    tasks = [bounded(uid) for uid in ids]

    iterator = asyncio.as_completed(tasks)

    if ENABLE_TQDM:
        iterator = tqdm(iterator, total=len(tasks), leave=False)

    for coro in iterator:
        result = await coro
        scanned += 1

        if result:
            user_states.append(result)

            if result["has_kid_profile"]:
                kids += 1

    return scanned, kids, user_states

async def main():
    run_started_at = datetime.now(timezone.utc)
    timeout = aiohttp.ClientTimeout(total=int(os.getenv("HTTP_TIMEOUT_SECONDS", "120")))

    connector = aiohttp.TCPConnector(
        limit=200,
        ttl_dns_cache=300,
        ssl=False,
    )

    async with aiohttp.ClientSession(
        timeout=timeout,
        connector=connector
    ) as session:
        if not await ensure_auth_token(session):
            raise RuntimeError("Auth token alınamadı. token_store.json içeriği kontrol edilmeli.")
        checkpoint = load_checkpoint()
        start_page = 1
        scanned_total = 0
        kids_total = 0
        all_states = []

        if checkpoint:
            start_page = int(checkpoint.get("last_page", 0)) + 1
            scanned_total = int(checkpoint.get("scanned_users", 0))
            kids_total = int(checkpoint.get("kids_users", 0))
            logger.info(
                    "[RESUME] page=%s last=%s scanned=%s kids=%s",
                    start_page,
                    checkpoint.get("last_page"),
                    scanned_total,
                    kids_total
                )


        first_ids, meta = await fetch_list_page(session, 0)

        if meta is None:
            raise RuntimeError("List endpoint fail: meta alınamadı. Script durduruldu.")

        active_total = meta.get("total")

        if first_ids is None and active_total:
            logger.warning("[FIRST PAGE EMPTY] active_total=%s", active_total)


        total_pages = meta.get("totalPage", 1)
        per_page = int(meta.get("perPage", PAGE_SIZE))
        pages_to_scan = total_pages if MAX_PAGES == 0 else min(MAX_PAGES, total_pages)



        # Page 1# Page 1 (resume değilsek)
        if start_page <= 1:
            s, k, states = await process_ids(session, first_ids)
            all_states.extend(states)
            
            scanned_total += s
            kids_total += k
            logger.info("[PROGRESS] page=1 scanned=%s kids=%s", scanned_total, kids_total)
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
                    logger.warning(
                            "[SKIP] page=%s offset=%s empty_or_failed cooldown=%.1fs",
                            page,
                            offset,
                            LIST_FAIL_COOLDOWN
                        )
                    await asyncio.sleep(LIST_FAIL_COOLDOWN)
                    continue

                s, k, states = await process_ids(session, ids)
                all_states.extend(states)
                
                scanned_total += s
                kids_total += k

                logger.info("[PROGRESS] page=%s scanned=%s kids=%s", page, scanned_total, kids_total)
                save_checkpoint(page, scanned_total, kids_total)

                if PAUSE_EVERY_PAGES and page % PAUSE_EVERY_PAGES == 0:
                    logger.info("[PAUSE] %.1f seconds", PAUSE_SECONDS)
                    await asyncio.sleep(PAUSE_SECONDS)

        else:
            logger.info("[SCAN ALREADY COMPLETE] skipping main scan")
    
        failed_pages = load_failed_pages()
        if failed_pages:
            logger.warning("[FAILED QUEUE] %s pages will be retried", len(failed_pages))

        for round_no in range(1, FAILED_RETRY_ROUNDS + 1):
            failed_pages = load_failed_pages()
            if not failed_pages:
                break

            logger.warning(
                    "[FAILED ROUND] round=%s/%s pages=%s",
                    round_no,
                    FAILED_RETRY_ROUNDS,
                    len(failed_pages)
                )
            still_failed = []

            for page in failed_pages:
                offset = (page - 1) * per_page
                ids, _meta = await fetch_list_page(session, offset)

                if ids is None:
                    still_failed.append(page)
                    continue

                s, k, states = await process_ids(session, ids)
                all_states.extend(states)
                
                scanned_total += s
                kids_total += k

                logger.info("[RECOVERED] page=%s scanned=%s kids=%s", page, scanned_total, kids_total)
                save_checkpoint(page, scanned_total, kids_total)

            save_failed_pages(still_failed)

            if still_failed:
                logger.warning(
                        "[FAILED ROUND REMAINING] round=%s remaining=%s cooldown=%.0fs",
                        round_no,
                        len(still_failed),
                        FAILED_ROUND_COOLDOWN
                    )
                await asyncio.sleep(FAILED_ROUND_COOLDOWN)
                
        # en son rapor
    run_finished_at = datetime.now(timezone.utc)
    duration_seconds = (run_finished_at - run_started_at).total_seconds()

    logger.info(
        "[RESULT] started=%s finished=%s duration_min=%.2f active_total=%s scanned_total=%s kids_total=%s state_rows=%s",
        run_started_at.isoformat(),
        run_finished_at.isoformat(),
        duration_seconds / 60,
        active_total,
        scanned_total,
        kids_total,
        len(all_states)
    )

    save_final_result(
        active_total,
        scanned_total,
        kids_total,
        len(all_states),
        run_started_at,
        run_finished_at
    )
    write_user_states_to_bq(all_states)
    write_snapshot_to_bq()

    clear_run_state()

    logger.info("[RUN STATE RESET] ready for next execution")


if __name__ == "__main__":
    asyncio.run(main())