import boto3
import pandas as pd
import json
import re
import os
import requests
import logging
from datetime import timedelta
from google.cloud import bigquery
from airflow.providers.google.cloud.hooks.bigquery import BigQueryHook
from airflow.providers.slack.operators.slack_webhook import SlackWebhookOperator

logger = logging.getLogger(__name__)
BQ_PROJECT_ID = 'microgain-9f959'
BQ_DATASET_ID = 'aws_s3_to_bq_migration'
BQ_TABLE_NAME = 'iys_subs'
TEAMS_WEBHOOK_URL = "https://astav2019.webhook.office.com/webhookb2/2b882404-4032-424d-9fc4-5d4c2e8c84d5@46a5e2a3-6015-4c6c-b96c-eaebfe5b2329/IncomingWebhook/5a44d3afe0cc419b99a5f223f2f42c8c/95cc1d9a-876c-4566-add7-e62cee46926b/V2IO3p9Dft06nFTeAHJJwHm2X4srP976IWwPXvknDLVlk1"

def send_teams_alert(message, context=None):
    dag_id = context['dag'].dag_id if context else 'Unknown DAG'
    run_id = context['dag_run'].run_id if context else 'Unknown Run'
    task_id = context['task_instance'].task_id if context else 'Unknown Task'
    payload = {"text": f"[DAG: {dag_id} | Run: {run_id} | Task: {task_id}]\n{message}"}
    headers = {"Content-Type": "application/json"}
    try:
        response = requests.post(TEAMS_WEBHOOK_URL, headers=headers, json=payload)
        response.raise_for_status()
        logger.info("✅ Teams mesajı gönderildi.")
    except requests.exceptions.RequestException as e:
        logger.error(f"❌ Teams mesajı gönderilemedi: {e}")

def send_slack_message(message, context):
    dag_id = context['dag'].dag_id if context else 'Unknown DAG'
    run_id = context['dag_run'].run_id if context else 'Unknown Run'
    task_id = context['task_instance'].task_id if context else 'Unknown Task'
    slack_message = f"[DAG: {dag_id} | Run: {run_id} | Task: {task_id}]\n{message}"
    try:
        SlackWebhookOperator(
            task_id=f"send_slack_alert_{context['task_instance'].try_number}",
            slack_webhook_conn_id="slack_default",
            message=slack_message,
            username="airflow_bot"
        ).execute(context=context)
    except Exception as e:
        logger.error(f"❌ Slack mesajı gönderilemedi: {e}")

def check_s3_path_exists(s3_bucket, s3_key):
    s3 = boto3.client('s3')
    result = s3.list_objects_v2(Bucket=s3_bucket, Prefix=s3_key, MaxKeys=1)
    return 'Contents' in result

def move_to_fail_path(bucket_name, file_key, fail_base_path, context):
    s3 = boto3.client('s3')
    try:
        file_name = os.path.basename(file_key)
        match = re.search(r'success/(\d{4})/(\d{2})/(\d{2})/(\d{2})/(.+)', file_key)
        if not match:
            raise ValueError(f"Dosya ismi beklenen formatta değil: {file_key}")

        year, month, day, hour, file = match.groups()
        fail_path = f"{fail_base_path}/success/{year}/{month}/{day}/{hour}/{file}"

        s3.copy_object(
            Bucket=bucket_name,
            CopySource={'Bucket': bucket_name, 'Key': file_key},
            Key=fail_path
        )
        s3.delete_object(Bucket=bucket_name, Key=file_key)
        logger.info(f"✅ Dosya fail path'e taşındı: {fail_path}")
    except Exception as e:
        logger.error(f"❌ Dosya fail path'e taşınamadı: {file_key} → {e}")
        send_teams_alert(f"❌ Dosya fail path'e taşınamadı: {file_key} → {e}", context)

def normalize_column_names(columns):
    normalized = []
    for col in columns:
        col = re.sub(r'(.)([A-Z][a-z]+)', r'\1_\2', col)
        col = re.sub(r'([a-z0-9])([A-Z])', r'\1_\2', col)
        col = col.strip().lower().replace(' ', '_')
        normalized.append(col)
    return normalized

def list_all_objects(bucket_name, prefix):
    s3 = boto3.client('s3')
    continuation_token = None
    all_objects = []

    while True:
        list_kwargs = {'Bucket': bucket_name, 'Prefix': prefix}
        if continuation_token:
            list_kwargs['ContinuationToken'] = continuation_token

        response = s3.list_objects_v2(**list_kwargs)

        contents = response.get('Contents', [])
        all_objects.extend(contents)

        if response.get('IsTruncated'):
            continuation_token = response.get('NextContinuationToken')
        else:
            break

    return all_objects

def insert_data_to_bq(bucket_name, fail_base_path, **context):
    execution_date = context['execution_date']
    s3_path = execution_date.strftime('success/%Y/%m/%d/%H/')
    inserted_dt = (execution_date + timedelta(hours=1)).strftime('%Y-%m-%d %H:%M:%S')

    bq_hook = BigQueryHook(gcp_conn_id='google_cloud_default_full')
    client = bq_hook.get_client(project_id=BQ_PROJECT_ID)
    table_ref = f"{BQ_PROJECT_ID}.{BQ_DATASET_ID}.{BQ_TABLE_NAME}"

    try:
        delete_query = f"DELETE FROM `{table_ref}` WHERE inserted_date = TIMESTAMP('{inserted_dt}')"
        logger.info(f"🗑️ Çalıştırılacak DELETE Query:\n{delete_query}")

        delete_job = client.query(delete_query)
        delete_result = delete_job.result()


        deleted_rows = delete_job._properties.get('statistics', {}).get('query', {}).get('dmlStats', {}).get(
            'deletedRowCount', 0)

        logger.info(f"✅ DELETE işlemi tamamlandı. Silinen satır sayısı: {deleted_rows}. Silinen saat: {inserted_dt}")

    except Exception as e:
        msg = f"❌ Delete işlemi başarısız: {e}"
        logger.error(msg)
        send_teams_alert(msg, context)
        send_slack_message(msg, context)
        return

    if not check_s3_path_exists(bucket_name, s3_path):
        msg = f"⚠️ S3 path {s3_path} bulunamadı."
        send_teams_alert(msg, context)
        send_slack_message(msg, context)
        return

    objects = list_all_objects(bucket_name, s3_path)
    all_rows = []
    schema = client.get_table(table_ref).schema
    valid_columns = [field.name for field in schema]

    for obj in objects:
        key = obj['Key']
        try:
            body = boto3.client('s3').get_object(Bucket=bucket_name, Key=key)['Body'].read()
            json_data = json.loads(body)
            if isinstance(json_data, dict):
                json_data = [json_data]
            df = pd.DataFrame(json_data)

            df.columns = normalize_column_names(df.columns)
            df = df[[col for col in df.columns if col in valid_columns]]
            df['inserted_date'] = inserted_dt

            if df.empty:
                logger.warning(f"⚠️ Boş dosya: {key}")
                continue

            all_rows.extend(df.to_dict(orient='records'))

        except Exception as e:
            msg = f"❌ Dosya işlenemedi: {key} → {e}"
            logger.error(msg)
            send_slack_message(msg, context)
            send_teams_alert(msg, context)
            move_to_fail_path(bucket_name, key, fail_base_path, context)

    if not all_rows:
        msg = "⚠️ Insert edilecek kayıt bulunamadı."
        send_teams_alert(msg, context)
        send_slack_message(msg, context)
        return

    batch_size = 1000
    errors = []
    for i in range(0, len(all_rows), batch_size):
        batch = all_rows[i:i + batch_size]
        result = client.insert_rows_json(table_ref, batch)
        if result:
            errors.extend(result)

    if errors:
        msg = f"❌ Insert hatası: {errors}"
        logger.error(msg)
        send_teams_alert(msg, context)
        send_slack_message(msg, context)
    else:
        msg = f"✅ Toplam {len(all_rows)} satır yüklendi: {table_ref}"
        logger.info(msg)
        #send_teams_alert(msg, context)
        #send_slack_message(msg, context)
