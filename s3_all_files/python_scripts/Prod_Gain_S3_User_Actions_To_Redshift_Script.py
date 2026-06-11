import boto3
import json
import re
import requests
import psycopg2
import logging
import threading
import queue
from urllib.parse import unquote
from datetime import datetime, timedelta
from airflow.hooks.base import BaseHook
from airflow.providers.slack.operators.slack_webhook import SlackWebhookOperator
from psycopg2.extras import execute_values

TEAMS_WEBHOOK_URL = "https://astav2019.webhook.office.com/webhookb2/2b882404-4032-424d-9fc4-5d4c2e8c84d5@46a5e2a3-6015-4c6c-b96c-eaebfe5b2329/IncomingWebhook/5a44d3afe0cc419b99a5f223f2f42c8c/95cc1d9a-876c-4566-add7-e62cee46926b/V2IO3p9Dft06nFTeAHJJwHm2X4srP976IWwPXvknDLVlk1"  # gizli
logger = logging.getLogger(__name__)
logging.basicConfig(level=logging.INFO)

file_queue = queue.Queue()
lock = threading.Lock()

# Her thread'e özel S3 client ver
s3_clients = [boto3.client('s3') for _ in range(5)]

def send_teams_alert(message, context=None):
    dag_id = context['dag'].dag_id if context else 'Unknown DAG'
    run_id = context['dag_run'].run_id if context else 'Unknown Run'
    task_id = context['task_instance'].task_id if context else 'Unknown Task'
    payload = {"text": f"[DAG: {dag_id} | Run: {run_id} | Task: {task_id}]\n{message}"}
    headers = {"Content-Type": "application/json"}
    try:
        requests.post(TEAMS_WEBHOOK_URL, headers=headers, json=payload)
    except Exception as e:
        logger.error(f"❌ Teams mesajı gönderilemedi: {e}")

def send_slack_message(message, context):
    try:
        SlackWebhookOperator(
            task_id=f"send_slack_alert_{context['task_instance'].try_number}",
            slack_webhook_conn_id="slack_default",
            message=f"[DAG: {context['dag'].dag_id} | Run: {context['dag_run'].run_id} | Task: {context['task_instance'].task_id}]\n{message}",
            username="airflow_bot"
        ).execute(context=context)
    except Exception as e:
        logger.error(f"❌ Slack mesajı gönderilemedi: {e}")

def move_to_fail_path(s3, bucket_name, file_name, fail_base_path):
    try:
        file_path = unquote(file_name.lstrip('/')).replace(' ', '')
        match = re.search(r'success/(\d{4})/(\d{2})/(\d{2})/(\d{2})/(.+)', file_path)
        if not match:
            logger.error(f"❌ Fail path regex eşleşmedi: {file_path}")
            return

        year, month, day, hour, file = match.groups()
        fail_path = f"{fail_base_path}/success/{year}/{month}/{day}/{hour}/{file}"
        s3.copy_object(Bucket=bucket_name, CopySource={'Bucket': bucket_name, 'Key': file_path}, Key=fail_path)
        s3.delete_object(Bucket=bucket_name, Key=file_path)
        logger.info(f"📦 Dosya fail_path'e taşındı: {fail_path}")
    except Exception as e:
        logger.error(f"❌ Dosya taşıma hatası: {str(e)}")


def file_worker(thread_index, bucket_name, inserted_date, rows_list, fail_list, context):
    s3 = s3_clients[thread_index]
    while not file_queue.empty():
        try:
            file_key = file_queue.get_nowait()
        except queue.Empty:
            break

        try:
            obj = s3.get_object(Bucket=bucket_name, Key=file_key)
            lines = obj['Body'].read().decode('utf-8').splitlines()
            local_rows = []

            for line in lines:
                try:
                    record = json.loads(line)
                    local_rows.append((
                        record.get('status'),
                        record.get('userId'),
                        record.get('email'),
                        record.get('verificationAt') if record.get('status') == 'VERIFY_EMAIL' else None,
                        record.get('createdAt'),
                        record.get('hasTVToken') if record.get('status') == 'SIGNUP' else None,
                        inserted_date
                    ))
                except Exception as parse_error:
                    move_to_fail_path(s3, bucket_name, file_key, 'copy_fail_files')

                    with lock:
                        fail_list.append(file_key)
                    send_teams_alert(f"🚨 JSON parse hatası\nDosya: {file_key}\nHata: {parse_error}", context)
                    send_slack_message(f"🚨 JSON parse hatası\nDosya: {file_key}\nHata: {parse_error}", context)
                    break

            with lock:
                rows_list.extend(local_rows)
        except Exception as e:
            move_to_fail_path(s3, bucket_name, file_key, 'copy_fail_files')

            with lock:
                fail_list.append(file_key)
            send_teams_alert(f"🚨 Dosya okuma hatası\nDosya: {file_key}\nHata: {e}", context)
            send_slack_message(f"🚨 Dosya okuma hatası\nDosya: {file_key}\nHata: {e}", context)

        file_queue.task_done()

def insert_data(bucket_name, s3_path, execution_date, **context):
    inserted_date = (execution_date + timedelta(hours=1)).strftime('%Y-%m-%d %H:%M:%S')
    logger.info(f"⏰ Inserted Date: {inserted_date}")

    pages = boto3.client('s3').get_paginator('list_objects_v2').paginate(Bucket=bucket_name, Prefix=s3_path)
    all_files = [obj['Key'] for page in pages for obj in page.get('Contents', [])]

    if not all_files:
        msg = f"❌ S3 Path'te dosya yok: {s3_path}"
        send_teams_alert(msg, context)
        send_slack_message(msg, context)
        return

    for key in all_files:
        file_queue.put(key)

    rows = []
    failed_files = []

    threads = []
    for i in range(min(16, len(all_files))):
        t = threading.Thread(target=file_worker, args=(i % 5, bucket_name, inserted_date, rows, failed_files, context))
        t.start()
        threads.append(t)

    for t in threads:
        t.join()

    redshift_conn = BaseHook.get_connection('Redshift_Serverless_Prod_User')
    conn = psycopg2.connect(
        dbname='gain-dwh-prod',
        user=redshift_conn.login,
        password=redshift_conn.password,
        host=redshift_conn.host,
        port=redshift_conn.port
    )
    cursor = conn.cursor()

    try:
        if rows:
            insert_query = """
                INSERT INTO int_transaction.user_actions_prod 
                (status, user_id, email, verification_at, created_at, has_tv_token, inserted_date)
                VALUES %s
            """
            execute_values(cursor, insert_query, rows)
            conn.commit()
    except Exception as e:
        send_teams_alert(f"🚨 Redshift insert hatası: {e}", context)
        send_slack_message(f"🚨 Redshift insert hatası: {e}", context)
        conn.rollback()
    finally:
        cursor.close()
        conn.close()

    logger.info(f"📁 Toplam dosya sayısı: {len(all_files)}")
    logger.info(f"📌 Insert edilen satır: {len(rows)}")
    logger.info(f"🟥 Fail path'e taşınan dosya: {len(failed_files)}")
    print(f"📁 Toplam dosya sayısı: {len(all_files)}")
    print(f"📌 Insert edilen satır: {len(rows)}")
    print(f"🟥 Fail path'e taşınan dosya: {len(failed_files)}")
