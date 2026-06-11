from airflow.providers.slack.operators.slack_webhook import SlackWebhookOperator
from airflow.providers.google.cloud.hooks.bigquery import BigQueryHook
from airflow.exceptions import AirflowFailException
from botocore.exceptions import ClientError
from airflow.hooks.base import BaseHook
from jinja2 import Template
import pandas as pd
import traceback
import requests
import logging
import math
import boto3


logger = logging.getLogger(__name__)
TEAMS_WEBHOOK_URL = "https://astav2019.webhook.office.com/webhookb2/2b882404-4032-424d-9fc4-5d4c2e8c84d5@46a5e2a3-6015-4c6c-b96c-eaebfe5b2329/IncomingWebhook/5a2388a0569a43a7a944f184a69635db/fb28b310-977e-4958-8a58-3320ed69daa1/V28Ia8HRdbwvvdZQXU_P5y9rD9HJ14eeviSYnzCFGWSZg1"

MAX_MSG_LEN = 250


def _shorten_message(message: str, limit: int = MAX_MSG_LEN) -> str:
    if not message:
        return ""
    message = str(message)
    if len(message) > limit:
        return message[:limit] + "... (truncated)"
    return message

def send_teams_alert(message, context=None):
    dag_id = context['dag'].dag_id if context and 'dag' in context else 'Unknown DAG'
    run_id = context['dag_run'].run_id if context and 'dag_run' in context else 'Unknown Run'
    task_id = context['task_instance'].task_id if context and 'task_instance' in context else 'Unknown Task'

    short_msg = _shorten_message(message)
    full_message = f"[DAG: {dag_id} | Run: {run_id} | Task: {task_id}]\n{short_msg}"

    payload = {"text": full_message}
    headers = {"Content-Type": "application/json"}
    try:
        response = requests.post(TEAMS_WEBHOOK_URL, headers=headers, json=payload)
        response.raise_for_status()
        logger.info("✅ Teams mesajı gönderildi!")
    except requests.exceptions.RequestException as e:
        logger.error(f"❌ Teams mesajı gönderilemedi: {e}")

def send_slack_message(message, context):
    dag_id = context['dag'].dag_id if 'dag' in context else 'Unknown DAG'
    run_id = context['dag_run'].run_id if 'dag_run' in context else 'Unknown Run'
    task_id = context['task_instance'].task_id if 'task_instance' in context else 'Unknown Task'

    short_msg = _shorten_message(message)
    full_message = f"[DAG: {dag_id} | Run: {run_id} | Task: {task_id}]\n{short_msg}"

    SlackWebhookOperator(
        task_id=f'send_slack_message_{context["task_instance"].try_number}',
        slack_webhook_conn_id='slack_default',
        message=full_message,
        username='airflow_bot',
    ).execute(context=context)
    print(full_message)

def _notify_and_fail(stage: str, err: Exception, context=None):
    tb = traceback.format_exc()
    tail = "\n".join(tb.splitlines()[-5:])
    msg = f"❌ Hata aşaması: {stage}\nHata: {err}\nTrace (son satırlar):\n{tail}"
    send_teams_alert(msg, context=context)
    send_slack_message(msg, context=context)
    raise AirflowFailException(f"{stage} aşamasında hata: {err}")


# S3 connection and get sql script
def get_sql_script_from_s3(key):
    s3 = boto3.client('s3')
    bucket_name = 'gain-data-airflow-bucket'
    try:
        return s3.get_object(Bucket=bucket_name, Key=key)['Body'].read().decode('utf-8')
    except ClientError as e:
        msg = f"S3 {key} path kontrolü sırasında hata oluştu: {str(e)}"
        logger.error(msg)
        raise Exception(msg)

def render_sql_from_s3(key, context):
    sql = get_sql_script_from_s3(key)
    template = Template(sql)

    dis = (context or {}).get('data_interval_start')
    die = (context or {}).get('data_interval_end')

    start_ts = dis.isoformat() if hasattr(dis, "isoformat") else str(dis)
    end_ts   = die.isoformat() if hasattr(die, "isoformat") else str(die)

    return template.render(data_interval_start=start_ts, data_interval_end=end_ts)

def get_insider_connection_info():
    conn = BaseHook.get_connection("insider_prod")
    headers = conn.extra_dejson.get("headers", {})  # Burada sadece sabit olanlar kalacak
    headers["Content-Type"] = "application/json"
    headers["X-REQUEST-TOKEN"] = conn.password  # 👈 token buradan güvenli şekilde geliyor
    host = conn.host
    return host, headers


def get_updated_users_from_bq(**kwargs):
    stage = "BQ:get_updated_users_from_bq"
    try:
        hook = BigQueryHook(gcp_conn_id="google_cloud_default_full", use_legacy_sql=False)
        sql = render_sql_from_s3(
            'sql_scripts/never_watched_insider_sql/get_all_current_never_watched_users_to_push_upsert_api.sql',
            kwargs
        )
        df = hook.get_pandas_df(sql=sql)
        logger.info(f"✅ BigQuery'den {0 if df is None else len(df)} kayıt alındı.")
        return df
    except Exception as e:
        msg = f"BigQuery verisi alınırken hata oluştu: {str(e)}"
        logger.error(msg)
        _notify_and_fail(stage, e, context=kwargs)


def send_users_to_insider(**context):
    stage = "Insider:Push_updated_segmented_users_to_insider"
    try:
        df = get_updated_users_from_bq(**context)
        if df is None or df.empty:
            logger.warning("⚠️ Gönderilecek kullanıcı yok (DataFrame boş).")
            context['ti'].xcom_push(key='total_sent', value=0)
            return

        host, headers = get_insider_connection_info()
        endpoint = f"{host.rstrip('/')}/api/user/v1/upsert"
        batch_size = 500
        num_batches = math.ceil(len(df) / batch_size)

        total_success = 0
        total_fail = 0

        for i in range(num_batches):
            batch = df.iloc[i * batch_size : (i + 1) * batch_size]
            users = []

            for _, row in batch.iterrows():
                email = row.get("email_address")
                uuid  = row.get("uuid")

                email = None if pd.isna(email) or str(email).strip()=="" else str(email)
                uuid  = None if pd.isna(uuid)  or str(uuid).strip()==""  else str(uuid)

                # en az bir identifier zorunlu
                if email is None and uuid is None:
                    continue

                watching_status = None if pd.isna(row.get("watching_status")) else str(row.get("watching_status"))
                val = row.get("isEmailPermitted")
                is_email_permitted = None if pd.isna(val) else bool(val)

                user_payload = {
                    "identifiers": {"uuid": uuid, "email": email},
                    "attributes": {
                        "custom": {
                            "watching_status": watching_status,          # JSON null olabilir
                            "is_email_permitted": is_email_permitted     # JSON null olabilir
                        }
                    }
                }
                users.append(user_payload)

            if not users:
                logger.info(f"Batch {i+1}/{num_batches}: boş; atlıyorum.")
                continue

            payload = {"skip_hook": False, "users": users}

            try:
                resp = requests.post(endpoint, headers=headers, json=payload, timeout=(5,30))
                resp.raise_for_status()
                result = resp.json() if resp.headers.get("Content-Type","").startswith("application/json") else {}
                total_success += result.get("data", {}).get("successful", {}).get("count", 0)
                total_fail    += result.get("data", {}).get("fail",        {}).get("count", 0)
            except requests.RequestException as re:
                logger.error(f"❌ Batch {i+1}/{num_batches} FAILED: {re}")
                total_fail += len(users)

        logger.info(f"📦 Toplam başarılı kullanıcı sayısı: {total_success}")
        logger.info(f"📉 Toplam başarısız kullanıcı sayısı: {total_fail}")
        context['ti'].xcom_push(key='total_sent', value=total_success)

    except Exception as e:
        msg = f"never_watched segmented user'ları için Insider'a veri gönderiminde hata oluştu: {str(e)}"
        logger.error(msg)
        _notify_and_fail(stage, e, context=context)

