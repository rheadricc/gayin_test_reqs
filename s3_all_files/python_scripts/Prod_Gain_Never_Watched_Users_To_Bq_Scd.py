from airflow.providers.slack.operators.slack_webhook import SlackWebhookOperator
from airflow.providers.google.cloud.hooks.bigquery import BigQueryHook
from airflow.exceptions import AirflowFailException
from botocore.exceptions import ClientError
from google.cloud import bigquery
import boto3, logging, requests, traceback

# Logger
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
    msg = f"❌ Hata aşaması: {stage}\nHata: {err}\nTrace (son satırlar):\n{tb.splitlines()[-5:]}"
    send_teams_alert(msg, context=context)
    send_slack_message(msg, context=context)
    raise AirflowFailException(f"{stage} aşamasında hata: {err}")

def run_sql_ordered(**kwargs):
    # BigQuery client
    try:
        hook = BigQueryHook(gcp_conn_id="google_cloud_default")
        credentials = hook.get_credentials()
        project_id = hook.project_id
        bq_client = bigquery.Client(credentials=credentials, project=project_id)
    except Exception as e:
        _notify_and_fail("BigQuery bağlantısı", e, context=kwargs)

    # S3
    try:
        s3 = boto3.client("s3")
    except Exception as e:
        _notify_and_fail("S3 client oluşturma", e, context=kwargs)

    bucket_name = "gain-data-airflow-bucket"
    prefix = "sql_scripts/never_watched_insider_sql"

    # Çalıştırma sırası
    sql_keys = [
        f"{prefix}/segmented_user_table.sql",
        f"{prefix}/guncel_premium_user.sql",
        f"{prefix}/never_watched_user_paid.sql",
        f"{prefix}/new_never_watched_user_a.sql",      # scd güncelleme A
        f"{prefix}/updated_never_watched_user_b.sql",  # scd güncelleme B
    ]

    job_config = bigquery.QueryJobConfig(use_legacy_sql=False)

    for i, key in enumerate(sql_keys, 1):
        stage = f"{i}/{len(sql_keys)} - {key}"
        try:
            sql = s3.get_object(Bucket=bucket_name, Key=key)["Body"].read().decode("utf-8")
        except Exception as e:
            _notify_and_fail(f"S3 okuma ({stage})", e, context=kwargs)

        try:
            job = bq_client.query(sql, job_config=job_config)
            job.result()  # bloklayıcı: bir sorgu bitmeden diğeri başlamaz
            logger.info(f"[{i}/{len(sql_keys)}] {key} başarıyla çalıştı. job_id={job.job_id}")
        except Exception as e:
            _notify_and_fail(f"BigQuery çalıştırma ({stage})", e, context=kwargs)
