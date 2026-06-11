import boto3
import json
import logging
import requests
from datetime import timedelta
from airflow.providers.google.cloud.hooks.bigquery import BigQueryHook
from airflow.providers.slack.operators.slack_webhook import SlackWebhookOperator

logger = logging.getLogger(__name__)

TEAMS_WEBHOOK_URL = "https://astav2019.webhook.office.com/webhookb2/2b882404-4032-424d-9fc4-5d4c2e8c84d5@46a5e2a3-6015-4c6c-b96c-eaebfe5b2329/IncomingWebhook/5a44d3afe0cc419b99a5f223f2f42c8c/95cc1d9a-876c-4566-add7-e62cee46926b/V2IO3p9Dft06nFTeAHJJwHm2X4srP976IWwPXvknDLVlk1"  # gerçek URL ile değiştir

def send_teams_alert(message, context=None):
    dag_id = context['dag'].dag_id if context and 'dag' in context else 'Unknown DAG'
    run_id = context['dag_run'].run_id if context and 'dag_run' in context else 'Unknown Run'
    task_id = context['task_instance'].task_id if context and 'task_instance' in context else 'Unknown Task'
    full_message = f"[DAG: {dag_id} | Run: {run_id} | Task: {task_id}]\n{message}"

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
    full_message = f"[DAG: {dag_id} | Run: {run_id} | Task: {task_id}]\n{message}"

    SlackWebhookOperator(
        task_id=f"send_slack_message_{context['task_instance'].try_number}",
        slack_webhook_conn_id='slack_default',
        message=full_message,
        username='airflow_bot',
    ).execute(context=context)
    print(full_message)


def run_validation(s3_bucket, s3_prefix_template, bq_table, execution_date, context):
    s3_prefix = execution_date.strftime(s3_prefix_template)
    start_ts = execution_date.replace(hour=1, minute=0, second=0)
    end_ts = start_ts + timedelta(days=1)

    logger.info(f"📅 Sorgu tarihi: {start_ts.strftime('%Y-%m-%d')}")
    logger.info(f"📂 S3 base klasör: s3://{s3_bucket}/{s3_prefix}")
    logger.info(f"🧮 BigQuery tablo: {bq_table}")

    try:
        # BigQuery satır sayısını al
        bq_query = f"""
            SELECT COUNT(*) as row_count
            FROM {bq_table}
            WHERE inserted_date >= TIMESTAMP('{start_ts.strftime('%Y-%m-%d %H:%M:%S')}')
              AND inserted_date < TIMESTAMP('{end_ts.strftime('%Y-%m-%d %H:%M:%S')}')
        """
        logger.info("📥 BigQuery COUNT sorgusu:")
        logger.info(bq_query.strip())

        bq_client = BigQueryHook(gcp_conn_id='google_cloud_default_full', use_legacy_sql=False).get_client()
        bq_result = list(bq_client.query(bq_query).result())[0]['row_count']

        # S3 saatlik dosya sayısını al
        s3 = boto3.client('s3')
        s3_total = 0
        hourly_counts = []

        for hour in range(24):
            hour_prefix = f"{s3_prefix}{hour:02d}/"
            count = 0
            paginator = s3.get_paginator('list_objects_v2')
            pages = paginator.paginate(Bucket=s3_bucket, Prefix=hour_prefix)
            for page in pages:
                count += sum(1 for obj in page.get('Contents', []) if obj['Key'].endswith('.json'))
            hourly_counts.append((hour, count))
            s3_total += count

        # Saat bazlı log yazdır
        log_lines = [f"🕒 {start_ts.strftime('%Y-%m-%d')}/{hour:02d} → {count} kayıt" for hour, count in hourly_counts]
        log_lines.append(f"\n📊 Toplam: BQ={bq_result} vs S3={s3_total}")

        full_log = "\n".join(log_lines)
        logger.info(full_log)

        if bq_result != s3_total:
            alert_msg = f"⚠️ Satır sayısı uyuşmazlığı!\n{full_log}"
            send_teams_alert(alert_msg, context)
            send_slack_message(alert_msg, context)
        else:
            logger.info("✅ Satır sayıları eşleşti.")

    except Exception as e:
        err_msg = f"❌ run_validation hata: {e}"
        logger.error(err_msg)
        send_teams_alert(err_msg, context)
        send_slack_message(err_msg, context)

