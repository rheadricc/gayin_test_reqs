import boto3
from urllib.parse import unquote
import re
import os
import requests
import json
import logging
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
        task_id=f'send_slack_message_{context["task_instance"].try_number}',
        slack_webhook_conn_id='slack_default',
        message=full_message,
        username='airflow_bot',
    ).execute(context=context)
    print(full_message)

def get_bq_client(gcp_conn_id='google_cloud_default_full'):
    hook = BigQueryHook(gcp_conn_id=gcp_conn_id, use_legacy_sql=False)
    return hook.get_client()

def read_files_from_s3(bucket_name, s3_path, context):
    s3 = boto3.client('s3')
    all_files = []
    try:
        paginator = s3.get_paginator('list_objects_v2')
        pages = paginator.paginate(Bucket=bucket_name, Prefix=s3_path)
        for page in pages:
            for obj in page.get('Contents', []):
                all_files.append(obj['Key'])
        if not all_files:
            raise ValueError("S3'te dosya bulunamadı.")
        logger.info(f"📁 S3'te bulunan dosya sayısı: {len(all_files)}")
        return all_files
    except Exception as e:
        msg = f"❌ S3 listeleme hatası: {e}"
        logger.error(msg)
        send_teams_alert(msg, context)
        send_slack_message(msg, context)
        raise

def parse_s3_file(bucket_name, file_key, inserted_date, context):
    s3 = boto3.client('s3')
    try:
        obj = s3.get_object(Bucket=bucket_name, Key=file_key)
        data = obj['Body'].read().decode('utf-8').splitlines()
        rows = []
        for line in data:
            record = json.loads(line)
            rows.append({
                'status': record.get('status'),
                'user_id': record.get('userId'),
                'email': record.get('email'),
                'verification_at': record.get('verificationAt') if record.get('status') == 'VERIFY_EMAIL' else None,
                'created_at': record.get('createdAt'),
                'has_tv_token': record.get('hasTVToken') if record.get('status') == 'SIGNUP' else None,
                'inserted_date': inserted_date
            })

        return rows
    except Exception as e:
        msg = f"❌ Dosya parse hatası: {file_key}\nHata: {e}"
        logger.error(msg)
        send_teams_alert(msg, context)
        send_slack_message(msg, context)
        raise

def insert_rows_to_bigquery_via_sql(rows, project_id, dataset_id, table_id, context, chunk_size=500):
    client = get_bq_client()

    try:
        if not rows:
            logger.warning("⚠️ Insert edilecek veri yok.")
            return 0

        total_inserted = 0
        for i in range(0, len(rows), chunk_size):
            chunk = rows[i:i + chunk_size]
            value_strs = []
            for row in chunk:
                value_str = f"""(
                    \"{row['status']}\",
                    \"{row['user_id']}\",
                    \"{row['email']}\",
                    {f"TIMESTAMP('{row['verification_at']}')" if row['verification_at'] else 'NULL'},
                    TIMESTAMP(\"{row['created_at']}\"),
                    {str(row['has_tv_token']).upper() if row['has_tv_token'] is not None else 'NULL'},
                    TIMESTAMP(\"{row['inserted_date']}\")
                )"""
                value_strs.append(value_str)

            insert_query = f"""
                INSERT INTO `{project_id}.{dataset_id}.{table_id}` (
                    status, user_id, email, verification_at, created_at, has_tv_token, inserted_date
                ) VALUES {', '.join(value_strs)}
            """

            logger.debug(f"🧩 SQL Query batch {i // chunk_size + 1} hazırlanıyor...")
            query_job = client.query(insert_query)
            query_job.result()
            logger.info(f"✅ SQL INSERT (batch {i // chunk_size + 1}) ile {len(chunk)} kayıt yüklendi.")
            total_inserted += len(chunk)

        return total_inserted

    except Exception as e:
        msg = f"❌ SQL INSERT hatası: {e}"
        logger.error(msg, exc_info=True)
        send_teams_alert(msg, context)
        send_slack_message(msg, context)
        raise

def move_to_fail_path(bucket_name, file_name, fail_base_path, context):
    s3 = boto3.client('s3')
    try:
        file_path = unquote(file_name.replace('s3://', '').lstrip('/')).replace(' ', '')
        file_name = os.path.basename(file_path)
        match = re.search(r'success/(\d{4})/(\d{2})/(\d{2})/(\d{2})/(.+)', file_path)
        if not match:
            raise ValueError(f"Dosya ismi format hatası: {file_name}")
        year, month, day, hour, file = match.groups()
        fail_path = f"copy_fail_files/success/{year}/{month}/{day}/{hour}/{file}"
        source_path = f"success/{year}/{month}/{day}/{hour}/{file}"
        s3.copy_object(Bucket=bucket_name, CopySource={'Bucket': bucket_name, 'Key': source_path}, Key=fail_path)
        s3.delete_object(Bucket=bucket_name, Key=source_path)
        logger.warning(f"❗ Dosya fail klasörüne taşındı: {fail_path}")
    except Exception as e:
        msg = f"❌ Fail klasörüne taşıma hatası: {file_name}\nHata: {e}"
        logger.error(msg)
        send_teams_alert(msg, context)
        send_slack_message(msg, context)
        raise


def insert_data_to_bigquery(bucket_name, s3_path, context):
    execution_date = context['execution_date']
    next_execution_date = context['next_execution_date']

    inserted_date_start = (execution_date + timedelta(hours=1)).strftime('%Y-%m-%d %H:%M:%S')
    inserted_date_end = (next_execution_date + timedelta(hours=1)).strftime('%Y-%m-%d %H:%M:%S')

    inserted_date = (execution_date + timedelta(hours=1)).strftime('%Y-%m-%d %H:%M:%S')

    project_id = 'microgain-9f959'
    dataset_id = 'aws_s3_to_bq_migration'
    table_id = 'user_actions'

    # 🔸 DELETE işlemi
    try:
        client = get_bq_client()
        delete_query = f"""
            DELETE FROM `{project_id}.{dataset_id}.{table_id}`
            WHERE inserted_date >= TIMESTAMP('{inserted_date_start}')
            AND inserted_date < TIMESTAMP('{inserted_date_end}')
        """
        logger.info("🗑️ Eski veriler siliniyor...")
        client.query(delete_query).result()
        logger.info("✅ Eski veriler başarıyla silindi.")
    except Exception as e:
        msg = f"❌ Delete işlemi başarısız: {e}"
        logger.error(msg)
        send_teams_alert(msg, context)
        send_slack_message(msg, context)
        return

    # 🔸 Dosya okuma ve işleme
    try:
        all_files = read_files_from_s3(bucket_name, s3_path, context)
    except Exception:
        return

    total_inserted = 0
    all_rows = []

    for file_key in all_files:
        try:
            rows = parse_s3_file(bucket_name, file_key, inserted_date, context)
            all_rows.extend(rows)
        except Exception:
            try:
                move_to_fail_path(bucket_name, f"s3://{bucket_name}/{file_key}", 'copy_fail_files', context)
            except Exception as move_err:
                msg = f"❌ Dosya taşınamadı: {file_key}\nHata: {move_err}"
                logger.error(msg)
                send_teams_alert(msg, context)
                send_slack_message(msg, context)

    try:
        total_inserted = insert_rows_to_bigquery_via_sql(all_rows, project_id, dataset_id, table_id, context)
    except Exception:
        logger.error("❌ Toplu insert işlemi başarısız oldu.")
        return

    logger.info(f"🎯 Toplam insert edilen kayıt sayısı: {total_inserted}")

