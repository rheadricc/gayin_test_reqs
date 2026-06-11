import boto3
import os
import json
import re
import pandas as pd
import requests
import psycopg2
import logging
from urllib.parse import unquote
from datetime import datetime, timedelta
from airflow.hooks.base import BaseHook
from airflow.providers.slack.operators.slack_webhook import SlackWebhookOperator
from psycopg2.extras import execute_values
TEAMS_WEBHOOK_URL = "https://astav2019.webhook.office.com/webhookb2/2b882404-4032-424d-9fc4-5d4c2e8c84d5@46a5e2a3-6015-4c6c-b96c-eaebfe5b2329/IncomingWebhook/5a44d3afe0cc419b99a5f223f2f42c8c/95cc1d9a-876c-4566-add7-e62cee46926b/V2IO3p9Dft06nFTeAHJJwHm2X4srP976IWwPXvknDLVlk1"  # Gerçek URL ile değiştir
logger = logging.getLogger(__name__)
logging.basicConfig(level=logging.INFO)


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


def move_to_fail_path(bucket_name, file_key, fail_base_path):
    s3 = boto3.client('s3')
    try:
        logger.info(f"🎯 move_to_fail_path başlatıldı: {file_key}")
        file_path = unquote(file_key)

        # Dosya gerçekten mevcut mu?
        try:
            s3.head_object(Bucket=bucket_name, Key=file_path)
            logger.info(f"✅ S3'te dosya bulundu: {file_path}")
        except Exception as exists_error:
            logger.warning(f"❌ Dosya S3'te mevcut değil → {file_path}")
            return

        # Regex match
        match = re.search(r'(success/\d{4}/\d{2}/\d{2}/\d{2}/.+)', file_path)
        if not match:
            logger.warning(f"❌ Regex eşleşmedi, taşıma iptal: {file_path}")
            return

        relative_path = match.group(1)
        fail_path = f"{fail_base_path}/{relative_path}"

        logger.info(f"📦 Kopyalanacak → {file_path} → {fail_path}")

        # Copy + Delete
        s3.copy_object(
            Bucket=bucket_name,
            CopySource={'Bucket': bucket_name, 'Key': file_path},
            Key=fail_path
        )
        logger.info("✅ S3 copy_object başarılı.")

        s3.delete_object(Bucket=bucket_name, Key=file_path)
        logger.info("🗑️ Orijinal dosya silindi.")

        logger.info(f"✅ Dosya taşındı: {fail_path}")

    except Exception as e:
        logger.exception(f"❌ move_to_fail_path başarısız | Dosya: {file_key}")






def delete_old_data(execution_date):
    inserted_start = (execution_date + timedelta(hours=1)).strftime('%Y-%m-%d %H:%M:%S')
    inserted_end = (execution_date + timedelta(hours=2)).strftime('%Y-%m-%d %H:%M:%S')

    redshift_conn = BaseHook.get_connection('Redshift_Serverless_Prod_User')
    conn = psycopg2.connect(
        dbname='gain-dwh-prod',
        user=redshift_conn.login,
        password=redshift_conn.password,
        host=redshift_conn.host,
        port=redshift_conn.port
    )
    cursor = conn.cursor()
    cursor.execute(f"""
        DELETE FROM int_subs.iys_subscriptions
        WHERE inserted_date >= '{inserted_start}'
        AND inserted_date < '{inserted_end}';
    """)
    conn.commit()
    cursor.close()
    conn.close()
    logger.info(f"🗑️ Eski veriler silindi: {inserted_start} - {inserted_end}")


def update_inserted_date(execution_date):
    inserted_date = (execution_date + timedelta(hours=1, seconds=30)).strftime('%Y-%m-%d %H:%M:%S')

    redshift_conn = BaseHook.get_connection('Redshift_Serverless_Prod_User')
    conn = psycopg2.connect(
        dbname='gain-dwh-prod',
        user=redshift_conn.login,
        password=redshift_conn.password,
        host=redshift_conn.host,
        port=redshift_conn.port
    )
    cursor = conn.cursor()
    cursor.execute(f"""
        UPDATE int_subs.iys_subscriptions
        SET inserted_date = '{inserted_date}'
        WHERE inserted_date IS NULL;
    """)
    conn.commit()
    cursor.close()
    conn.close()
    logger.info(f"⏱️ inserted_date NULL olan kayıtlar güncellendi: {inserted_date}")



def insert_data(bucket_name, s3_path, execution_date, **context):
    inserted_date = (execution_date + timedelta(hours=1)).strftime('%Y-%m-%d %H:%M:%S')
    logger.info(f"⏰ Inserted Date: {inserted_date}")

    s3 = boto3.client('s3')
    paginator = s3.get_paginator('list_objects_v2')
    pages = paginator.paginate(Bucket=bucket_name, Prefix=s3_path)

    all_files = [obj['Key'] for page in pages for obj in page.get('Contents', [])]
    file_count = len(all_files)

    if file_count == 0:
        msg = f"❌ S3 Path'te dosya yok: {s3_path}"
        logger.warning(msg)
        print(msg)
        send_teams_alert(msg, context)
        return

    redshift_conn = BaseHook.get_connection('Redshift_Serverless_Prod_User')
    conn = psycopg2.connect(
        dbname='gain-dwh-prod',
        user=redshift_conn.login,
        password=redshift_conn.password,
        host=redshift_conn.host,
        port=redshift_conn.port
    )
    cursor = conn.cursor()
    indexed_rows = []

    for file_key in all_files:
        try:
            obj = s3.get_object(Bucket=bucket_name, Key=file_key)
            data = obj['Body'].read().decode('utf-8').splitlines()

            for line in data:
                try:
                    record = json.loads(line)
                    row = (
                        record.get('status'),
                        record.get('user_id'),
                        record.get('full_name'),
                        record.get('email'),
                        record.get('is_email_permitted'),
                        record.get('platform'),
                        record.get('created_at'),
                        inserted_date
                    )
                    indexed_rows.append((row, file_key))
                except Exception as parse_error:
                    move_to_fail_path(bucket_name, file_key, 'copy_fail_files')
                    send_teams_alert(f"🚨 Parse Hatası! Dosya: {file_key}\nHata: {parse_error}", context)
                    send_slack_message(f"🚨 Parse Hatası! Dosya: {file_key}\nHata: {parse_error}", context)

        except Exception as e:
            # hatalı satır insert işleminde
            move_to_fail_path(bucket_name, file_key, 'copy_fail_files')
            send_teams_alert(f"🚨 Dosya okuma hatası: {file_key}\nHata: {e}", context)
            send_slack_message(f"🚨 Dosya okuma hatası: {file_key}\nHata: {e}", context)
            logger.info(f"🔁 move_to_fail_path çağrıldı: {file_key}")


    insert_query = """
        INSERT INTO int_subs.iys_subscriptions
        (status, user_id, full_name, email, is_email_permitted, platform, created_at, inserted_date)
        VALUES %s
    """

    try:
        if indexed_rows:
            # Toplu insert
            execute_values(cursor, insert_query, [row for row, _ in indexed_rows])
            conn.commit()
            logger.info(f"📌 Toplam insert edilen satır: {len(indexed_rows)}")
            print(f"📌 Toplam insert edilen satır: {len(indexed_rows)}")
        else:
            logger.warning("⚠️ Insert edilecek kayıt bulunamadı.")

    except Exception as batch_error:
        conn.rollback()
        logger.warning("🚨 Toplu insert başarısız oldu. Satır bazlı retry başlatılıyor...")

        for row, file_key in indexed_rows:
            try:
                execute_values(cursor, insert_query, [row])
                conn.commit()
            except Exception as row_error:
                conn.rollback()
                move_to_fail_path(bucket_name, file_key, 'copy_fail_files')
                send_teams_alert(f"🚨 Satır insert hatası\nDosya: {file_key}\nHata: {row_error}", context)
                send_slack_message(f"🚨 Satır insert hatası\nDosya: {file_key}\nHata: {row_error}", context)

    finally:
        cursor.close()
        conn.close()

    logger.info(f"📁 Toplam dosya sayısı: {file_count}")
    logger.info(f"📄 İşlenen dosya sayısı: {file_count}")
    logger.info(f"📊 Toplam toplanan kayıt: {len(indexed_rows)}")



