from airflow.providers.slack.hooks.slack_webhook import SlackWebhookHook
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

def send_slack_message(message, context=None):
    dag_id = context['dag'].dag_id if context and 'dag' in context else 'Unknown DAG'
    run_id = context['dag_run'].run_id if context and 'dag_run' in context else 'Unknown Run'
    task_id = context['task_instance'].task_id if context and 'task_instance' in context else 'Unknown Task'

    short_msg = _shorten_message(str(message))
    full_message = f"[DAG: {dag_id} | Run: {run_id} | Task: {task_id}]\n{short_msg}"

    try:
        hook = SlackWebhookHook(slack_webhook_conn_id='slack_default')
        hook.send(text=full_message)
        logger.info("✅ Slack mesajı gönderildi!")
    except Exception as e:
        logger.error(f"❌ Slack mesajı gönderilemedi: {e}")

def _notify_and_fail(stage: str, err: Exception, context=None):
    tb = traceback.format_exc()
    msg = f"❌ Hata aşaması: {stage}\nHata: {err}\nTrace (son satırlar):\n{tb.splitlines()[-5:]}"
    send_teams_alert(msg, context=context)
    send_slack_message(msg, context=context)
    raise AirflowFailException(f"{stage} aşamasında hata: {err}")

VALID_VERDICTS = {"LOW", "HIGH", "NO_BASELINE"}

def run_ga4_hourly_check(**kwargs):

    stage = "GA4 Hourly Check"
    bucket_name = "gain-data-airflow-bucket"
    sql_key = "sql_scripts/monitoring/ga4_hourly_event_check.sql"

    # BigQuery client
    try:
        hook = BigQueryHook(gcp_conn_id="google_cloud_default")
        credentials = hook.get_credentials()
        project_id = hook.project_id
        bq_client = bigquery.Client(credentials=credentials, project=project_id)
    except Exception as e:
        _notify_and_fail(f"{stage} - BigQuery bağlantısı", e, context=kwargs)

    # S3 client
    try:
        s3 = boto3.client("s3")
    except Exception as e:
        _notify_and_fail(f"{stage} - S3 client oluşturma", e, context=kwargs)

    # SQL oku
    try:
        sql = s3.get_object(Bucket=bucket_name, Key=sql_key)["Body"].read().decode("utf-8")
    except Exception as e:
        _notify_and_fail(f"{stage} - S3 SQL okuma ({sql_key})", e, context=kwargs)

    # Sorguyu çalıştır
    try:
        job = bq_client.query(sql, job_config=bigquery.QueryJobConfig(use_legacy_sql=False))
        result = job.result()
    except Exception as e:
        _notify_and_fail(f"{stage} - BigQuery query çalıştırma", e, context=kwargs)

    # Sonuçları işle (sadece anomali verdict'leri)
    anomalies = []
    total_rows = 0
    try:
        for row in result:
            total_rows += 1
            r = dict(row)
            verdict = str(r.get("verdict", "")).upper()
            if verdict not in VALID_VERDICTS:
                continue

            msg = r.get("alert_message")
            if not msg:
                hour = r.get("hour_tr")
                cnt = r.get("cur_cnt")
                low = r.get("low_band")
                high = r.get("high_band")
                msg = f"[GA4 Hourly] {hour} | cnt={cnt}, band=[{low}..{high}] -> {verdict}"
            anomalies.append(str(msg))
    except Exception as e:
        _notify_and_fail(f"{stage} - Sonuç okuma", e, context=kwargs)

    logger.info(f"[GA4 Hourly] BigQuery {total_rows} satır döndürdü; anomali {len(anomalies)}.")

    if not anomalies:
        logger.info("[GA4 Hourly] Anomali yok, mesaj gönderilmeyecek.")
        return

    # Spam azalt: tek mesaj
    MAX_LINES = 10
    head = anomalies[:MAX_LINES]
    tail_count = max(0, len(anomalies) - MAX_LINES)
    combined = "\n".join(head) + (f"\n[GA4 Hourly] +{tail_count} ek anomali daha var (mesaj kısaltıldı)." if tail_count > 0 else "")

    try:
        send_teams_alert(combined, context=kwargs)
        send_slack_message(combined, context=kwargs)
    except Exception as e:
        _notify_and_fail(f"{stage} - Alert gönderimi", e, context=kwargs)

    logger.info(f"[GA4 Hourly] {len(anomalies)} adet anomali bildirildi.")

