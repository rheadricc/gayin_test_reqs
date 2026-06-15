import os
import asyncio
import json
import hashlib
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

import aiohttp
import boto3
from botocore.exceptions import ClientError

try:
    from google.cloud import bigquery
except ImportError:
    bigquery = None


SCRIPT_VERSION = "bo_all_profiles_count_no_dotenv_no_tqdm_v2"



BASE_URL = os.getenv("PROD_BASE_URL", "https://api.gain.tv/2da7kf8jf").rstrip("/")

TOKEN_STORE_MODE = os.getenv("TOKEN_STORE_MODE", "s3").strip().lower()
S3_BUCKET = os.getenv("S3_BUCKET", "gain-data-airflow-bucket").strip()
S3_TOKEN_KEY = os.getenv("S3_TOKEN_KEY", "airflow_keys/token_store.json").strip()
LOCAL_TOKEN_STORE_PATH = os.getenv("LOCAL_TOKEN_STORE_PATH", "token_store.json").strip()
AUTH_TOKEN = os.getenv("AUTH_TOKEN", "").strip()

BQ_PROJECT_ID = os.getenv("BQ_PROJECT_ID", "microgain-9f959").strip()
BQ_TARGET_USERS_SQL = os.getenv("BQ_TARGET_USERS_SQL", "").strip()
BQ_MAX_USERS = int(os.getenv("BQ_MAX_USERS", "0"))
BQ_RESULT_TABLE = os.getenv("BQ_RESULT_TABLE", "microgain-9f959.bc_t.multi_profile_counter").strip()
SAVE_RESULT_TO_BIGQUERY = os.getenv("SAVE_RESULT_TO_BIGQUERY", "1").strip() == "1"

USER_VALID_UNTIL_LOOKBACK_DAYS = int(os.getenv("USER_VALID_UNTIL_LOOKBACK_DAYS", "90"))
USER_VALID_UNTIL_FROM_DATE = os.getenv("USER_VALID_UNTIL_FROM_DATE", "").strip()
PROFILE_CREATED_AFTER = os.getenv("PROFILE_CREATED_AFTER", "").strip()
TIMEZONE = os.getenv("TIMEZONE", "Europe/Istanbul").strip()

CONCURRENT_REQUESTS = int(os.getenv("MAX_WORKERS", "100"))
MAX_RETRIES = int(os.getenv("MAX_RETRIES", "3"))

DETAIL_URL_TMPL = f"{BASE_URL}/CALL/User/getUserDetailForBo/{{user_id}}"


def get_valid_until_from_date() -> str:
    if USER_VALID_UNTIL_FROM_DATE:
        return USER_VALID_UNTIL_FROM_DATE[:10]

    try:
        today = datetime.now(ZoneInfo(TIMEZONE)).date()
    except Exception:
        today = datetime.now().date()

    return (today - timedelta(days=USER_VALID_UNTIL_LOOKBACK_DAYS)).isoformat()


VALID_UNTIL_FROM_DATE = get_valid_until_from_date()
QUERY_HASH = hashlib.md5(
    f"valid_until>={VALID_UNTIL_FROM_DATE}|lookback_days={USER_VALID_UNTIL_LOOKBACK_DAYS}|profile_created_after={PROFILE_CREATED_AFTER}".encode("utf-8")
).hexdigest()


def normalize_bearer_token(token: str) -> str:
    token = (token or "").strip()
    if not token:
        return ""
    return token if token.lower().startswith("bearer ") else f"Bearer {token}"


def extract_access_token(tokens: dict) -> str:
    return (
        tokens.get("accessToken")
        or tokens.get("access_token")
        or tokens.get("token")
        or tokens.get("jwt")
        or ""
    )


def load_access_token() -> str:
    if AUTH_TOKEN:
        return normalize_bearer_token(AUTH_TOKEN)

    if TOKEN_STORE_MODE == "local":
        with open(LOCAL_TOKEN_STORE_PATH, "r", encoding="utf-8") as f:
            tokens = json.load(f)

        access_token = extract_access_token(tokens)
        if not access_token:
            raise ValueError(f"Lokal token store içinde accessToken yok: {LOCAL_TOKEN_STORE_PATH}")

        return normalize_bearer_token(access_token)

    try:
        response = boto3.client("s3").get_object(Bucket=S3_BUCKET, Key=S3_TOKEN_KEY)
        tokens = json.loads(response["Body"].read().decode("utf-8"))
    except ClientError as e:
        raise RuntimeError(f"S3 token store okunamadı: s3://{S3_BUCKET}/{S3_TOKEN_KEY} err={e}") from e

    access_token = extract_access_token(tokens)
    if not access_token:
        raise ValueError(f"S3 token store içinde accessToken yok: s3://{S3_BUCKET}/{S3_TOKEN_KEY}")

    return normalize_bearer_token(access_token)


def build_auth_headers() -> dict:
    return {
        "Authorization": load_access_token(),
        "Content-Type": "application/json",
        "User-Agent": "Python/aiohttp",
    }


def get_default_bq_target_users_sql() -> str:
    limit_clause = f"LIMIT {BQ_MAX_USERS}" if BQ_MAX_USERS > 0 else ""

    return f"""
    SELECT DISTINCT
      user_id
    FROM `microgain-9f959.aws_s3_to_bq_migration.subs_payment`
    WHERE user_id IS NOT NULL
      AND DATE(valid_until) >= DATE_SUB(CURRENT_DATE("Europe/Istanbul"), INTERVAL {USER_VALID_UNTIL_LOOKBACK_DAYS} DAY)
      AND status IN ('ACTIVE', 'CANCELED', 'ON_HOLD', 'IN_GRACE')
      AND subscription_plan_id IS NOT NULL
    {limit_clause}
    """


def get_bigquery_client():
    if bigquery is None:
        raise ImportError("google-cloud-bigquery paketi bulunamadı.")
    return bigquery.Client(project=BQ_PROJECT_ID)


def load_target_user_ids_from_bigquery():
    sql = BQ_TARGET_USERS_SQL or get_default_bq_target_users_sql()

    print("[BQ TARGET USERS] Query başlıyor...")
    print(sql)

    rows = get_bigquery_client().query(sql).result()
    user_ids = []
    seen = set()

    for row in rows:
        user_id = getattr(row, "user_id", None)
        if not user_id:
            continue

        user_id = str(user_id).strip()
        if not user_id or user_id in seen:
            continue

        seen.add(user_id)
        user_ids.append(user_id)

    print(f"[BQ TARGET USERS] loaded={len(user_ids)}")
    return user_ids


def ensure_result_table_exists():
    create_table_sql = f"""
    CREATE TABLE IF NOT EXISTS `{BQ_RESULT_TABLE}` (
      run_date DATE,
      scanned_accounts INT64,
      total_profiles INT64,
      avg_profiles_per_account FLOAT64,
      multi_profile_users INT64,
      single_profile_users INT64,
      valid_until_from_date DATE,
      query_hash STRING
    )
    """
    get_bigquery_client().query(create_table_sql).result()


def save_result_to_bigquery(scanned_accounts, total_profiles, multi_profile_users, single_profile_users):
    if not SAVE_RESULT_TO_BIGQUERY:
        print("[BQ RESULT SKIP] SAVE_RESULT_TO_BIGQUERY=0")
        return

    ensure_result_table_exists()

    avg_profiles_per_account = total_profiles / scanned_accounts if scanned_accounts else 0

    row = {
        "run_date": datetime.now(ZoneInfo(TIMEZONE)).date().isoformat(),
        "scanned_accounts": int(scanned_accounts or 0),
        "total_profiles": int(total_profiles or 0),
        "avg_profiles_per_account": float(avg_profiles_per_account),
        "multi_profile_users": int(multi_profile_users or 0),
        "single_profile_users": int(single_profile_users or 0),
        "valid_until_from_date": VALID_UNTIL_FROM_DATE,
        "query_hash": QUERY_HASH,
    }

    errors = get_bigquery_client().insert_rows_json(BQ_RESULT_TABLE, [row])
    if errors:
        raise RuntimeError(f"[BQ RESULT ERROR] {errors}")

    print(f"[BQ RESULT OK] table={BQ_RESULT_TABLE} run_date={row['run_date']} scanned={scanned_accounts}")


def print_final_result(scanned_accounts, users_with_profiles, total_profiles, multi_profile_users, single_profile_users):
    print("\n==== FINAL RESULT ====")
    print(f"Scanned Accounts: {scanned_accounts}")
    print(f"Accounts With At Least 1 Profile: {users_with_profiles}")
    print(f"Total Profiles: {total_profiles}")

    if scanned_accounts > 0:
        print(f"Avg Profiles Per Account: {total_profiles / scanned_accounts:.3f}")

    print(f"Multi Profile Users: {multi_profile_users}")
    print(f"Single Profile Users: {single_profile_users}")


async def fetch_user_profile_count(session, user_id: str) -> int:
    url = DETAIL_URL_TMPL.format(user_id=user_id)

    for attempt in range(MAX_RETRIES):
        try:
            async with session.get(url, timeout=30) as resp:
                if resp.status in (429, 500, 502, 503, 504):
                    sleep_s = min(20.0, 1.5 * (2 ** attempt))
                    print(f"[DETAIL RETRY] user_id={user_id} status={resp.status} sleep={sleep_s:.1f}s")
                    await asyncio.sleep(sleep_s)
                    continue

                resp.raise_for_status()
                payload = await resp.json()

            profiles = payload.get("profiles", [])
            if not isinstance(profiles, list):
                return 0

            profile_ids = set()

            for profile in profiles:
                if not isinstance(profile, dict):
                    continue

                profile_id = profile.get("id")
                if not profile_id:
                    continue

                if PROFILE_CREATED_AFTER:
                    created_at = profile.get("createdAt")
                    if not created_at or str(created_at)[:10] < PROFILE_CREATED_AFTER:
                        continue

                profile_ids.add(profile_id)

            return len(profile_ids)

        except Exception as e:
            sleep_s = min(20.0, 1.5 * (2 ** attempt))
            print(f"[DETAIL RETRY] user_id={user_id} err={type(e).__name__}: {e} sleep={sleep_s:.1f}s")
            await asyncio.sleep(sleep_s)

    print(f"[DETAIL FAIL] user_id={user_id} retries_exceeded")
    return 0


async def process_ids(session, user_ids):
    scanned_accounts = 0
    users_with_profiles = 0
    total_profiles = 0
    multi_profile_users = 0
    single_profile_users = 0

    if not user_ids:
        return 0, 0, 0, 0, 0

    semaphore = asyncio.Semaphore(CONCURRENT_REQUESTS)

    async def bounded(user_id):
        async with semaphore:
            return await fetch_user_profile_count(session, user_id)

    tasks = [bounded(user_id) for user_id in user_ids]

    total_tasks = len(tasks)

    for coro in asyncio.as_completed(tasks):
        profile_count = await coro
        scanned_accounts += 1
        total_profiles += profile_count

        if profile_count > 0:
            users_with_profiles += 1

        if profile_count == 1:
            single_profile_users += 1
        elif profile_count > 1:
            multi_profile_users += 1

        if scanned_accounts == 1 or scanned_accounts % 1000 == 0 or scanned_accounts == total_tasks:
            print(f"[PROGRESS] scanned={scanned_accounts}/{total_tasks}")

    return scanned_accounts, users_with_profiles, total_profiles, multi_profile_users, single_profile_users


async def main():
    if not BASE_URL:
        raise ValueError("PROD_BASE_URL boş.")

    print(f"[SCRIPT VERSION] {SCRIPT_VERSION}")

    auth_headers = build_auth_headers()
    if not auth_headers.get("Authorization"):
        raise ValueError("Authorization token alınamadı.")

    print(f"[CONFIG] MAX_WORKERS={CONCURRENT_REQUESTS} MAX_RETRIES={MAX_RETRIES}")
    print(f"[CONFIG] VALID_UNTIL_FROM_DATE={VALID_UNTIL_FROM_DATE} BQ_RESULT_TABLE={BQ_RESULT_TABLE}")
    print(f"[QUERY HASH] {QUERY_HASH}")

    target_user_ids = load_target_user_ids_from_bigquery()
    if not target_user_ids:
        print("[BQ TARGET USERS] Kullanıcı bulunamadı, işlem durduruldu.")
        return

    timeout = aiohttp.ClientTimeout(total=60)
    connector = aiohttp.TCPConnector(limit=max(200, CONCURRENT_REQUESTS * 2), ttl_dns_cache=300, ssl=False)

    async with aiohttp.ClientSession(headers=auth_headers, timeout=timeout, connector=connector) as session:
        scanned_accounts, users_with_profiles, total_profiles, multi_profile_users, single_profile_users = await process_ids(
            session,
            target_user_ids,
        )

    print_final_result(
        scanned_accounts,
        users_with_profiles,
        total_profiles,
        multi_profile_users,
        single_profile_users,
    )
    save_result_to_bigquery(
        scanned_accounts,
        total_profiles,
        multi_profile_users,
        single_profile_users,
    )


if __name__ == "__main__":
    asyncio.run(main())