import boto3
import pandas as pd
import gzip
import io
import re
import logging
from concurrent.futures import ThreadPoolExecutor, as_completed
from collections import defaultdict
from google.cloud import bigquery
from airflow.providers.google.cloud.hooks.bigquery import BigQueryHook
from airflow.hooks.base import BaseHook

logger = logging.getLogger(__name__)

AWS_CONN_ID = 'aws_default'
AWS_BUCKET_NAME = 'gain-adjust-data'
BQ_PROJECT_ID = 'microgain-9f959'
BQ_DATASET_ID = 'adjust_migration_to_bq'
BQ_TEMPLATE_TABLE = 'adjust_events_temblates'
BQ_TABLE_NAME_PREFIX = 'adjust_events'
MAX_PARALLEL_FILES = 4

def send_teams(message, context=None):
    import requests
    TEAMS_WEBHOOK_URL = "https://astav2019.webhook.office.com/webhookb2/2b882404-4032-424d-9fc4-5d4c2e8c84d5@46a5e2a3-6015-4c6c-b96c-eaebfe5b2329/IncomingWebhook/5a44d3afe0cc419b99a5f223f2f42c8c/95cc1d9a-876c-4566-add7-e62cee46926b/V2IO3p9Dft06nFTeAHJJwHm2X4srP976IWwPXvknDLVlk1"
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

def send_slack(message, context):
    from airflow.providers.slack.operators.slack_webhook import SlackWebhookOperator
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

def ensure_table_exists(client, table_ref, template_table_ref, context=None, send_slack=None, send_teams=None):
    from google.api_core.exceptions import NotFound
    try:
        client.get_table(table_ref)
    except NotFound:
        try:
            schema = client.get_table(template_table_ref).schema
            table = bigquery.Table(table_ref, schema=schema)
            client.create_table(table)
        except Exception as e:
            logger.error(f"❌ Tablo oluşturulamadı: {table_ref} → {e}")
            if send_slack: send_slack(f"❌ Tablo oluşturulamadı: {table_ref} → {e}", context)
            if send_teams: send_teams(f"❌ Tablo oluşturulamadı: {table_ref} → {e}", context)
            raise

def list_s3_files(execution_date, context=None, send_slack=None, send_teams=None):
    try:
        aws_conn = BaseHook.get_connection(AWS_CONN_ID)
        s3 = boto3.client(
            's3',
            aws_access_key_id=aws_conn.login,
            aws_secret_access_key=aws_conn.password,
            region_name='eu-west-1'
        )
        prefix = f"rx56k7zejjls_{execution_date}"
        response = s3.list_objects_v2(Bucket=AWS_BUCKET_NAME, Prefix=prefix)
        return [obj['Key'] for obj in response.get('Contents', [])] if 'Contents' in response else []
    except Exception as e:
        logger.error(f"❌ S3 list error: {e}")
        if send_slack: send_slack(f"S3 list error: {e}", context)
        if send_teams: send_teams(f"S3 list error: {e}", context)
        return []

def process_file(file_key):
    aws_conn = BaseHook.get_connection(AWS_CONN_ID)
    s3 = boto3.client(
        's3',
        aws_access_key_id=aws_conn.login,
        aws_secret_access_key=aws_conn.password,
        region_name='eu-west-1'
    )
    obj = s3.get_object(Bucket=AWS_BUCKET_NAME, Key=file_key)
    decompressed = gzip.GzipFile(fileobj=io.BytesIO(obj['Body'].read())).read()
    df = pd.read_csv(io.StringIO(decompressed.decode('utf-8')))
    df.columns = (
        df.columns
        .str.strip()
        .str.replace(r"[\{\}\[\]]", "", regex=True)
        .str.replace(r"\|\|", "_", regex=True)
        .str.replace(" ", "_")
        .str.lower()
    )
    match = re.search(r'rx56k7zejjls_(\d{4}-\d{2}-\d{2})T', file_key)
    if not match:
        raise ValueError(f"Tarih bulunamadi: {file_key}")
    file_date_str = match.group(1).replace('-', '')
    table_name = f"{BQ_TABLE_NAME_PREFIX}_{file_date_str}"
    return table_name, df

def process_files(context, send_slack, send_teams):
    execution_date = context['ds']
    files_to_process = list_s3_files(execution_date, context, send_slack, send_teams)

    if not files_to_process:
        msg = "⚠️ İşlenecek dosya bulunamadı."
        send_slack(msg, context)
        send_teams(msg, context)
        return

    data_by_table = defaultdict(list)
    total_files = 0
    total_rows = 0

    with ThreadPoolExecutor(max_workers=MAX_PARALLEL_FILES) as executor:
        futures = {
            executor.submit(process_file, file_key): file_key
            for file_key in files_to_process
        }
        for future in as_completed(futures):
            file_key = futures[future]
            try:
                table_name, df = future.result()
                data_by_table[table_name].append(df)
                total_files += 1
                total_rows += len(df)
            except Exception as e:
                logger.error(f"❌ {file_key} hatalı: {e}")
                send_slack(f"❌ {file_key} yüklenemedi → {e}", context)
                send_teams(f"❌ {file_key} yüklenemedi → {e}", context)

    bq_hook = BigQueryHook(gcp_conn_id='google_cloud_default_full')
    client = bq_hook.get_client(project_id=BQ_PROJECT_ID)

    for table_name, dfs in data_by_table.items():
        df_all = pd.concat(dfs, ignore_index=True)
        table_ref = f"{BQ_PROJECT_ID}.{BQ_DATASET_ID}.{table_name}"
        template_ref = f"{BQ_PROJECT_ID}.{BQ_DATASET_ID}.{BQ_TEMPLATE_TABLE}"
        try:
            ensure_table_exists(client, table_ref, template_ref, context, send_slack, send_teams)
            schema = client.get_table(table_ref).schema
            bq_schema = {field.name: field.field_type for field in schema}
            for col, dtype in bq_schema.items():
                if col in df_all.columns:
                    if dtype == 'STRING':
                        df_all[col] = df_all[col].astype(str)
                    elif dtype in ('INTEGER', 'INT64'):
                        df_all[col] = pd.to_numeric(df_all[col], errors='coerce').astype('Int64')
                    elif dtype == 'FLOAT':
                        df_all[col] = pd.to_numeric(df_all[col], errors='coerce')
                    elif dtype == 'TIMESTAMP':
                        df_all[col] = pd.to_datetime(df_all[col], errors='coerce')
            df_all = df_all[[col for col in bq_schema if col in df_all.columns]]
            job = client.load_table_from_dataframe(
                df_all,
                destination=table_ref,
                job_config=bigquery.LoadJobConfig(write_disposition="WRITE_TRUNCATE"),
                location='US'
            )
            job.result()
            logger.info(f"✅ Insert edildi: {table_ref} → {len(df_all)} satır")
        except Exception as e:
            send_slack(f"❌ Insert hatası: {table_name} → {e}", context)
            send_teams(f"❌ Insert hatası: {table_name} → {e}", context)

    summary = f"""
    📊 *İşlem Özeti*:
    - Toplam dosya: `{total_files}`
    - Toplam satır: `{total_rows}`
    - Tablo sayısı: `{len(data_by_table)}`
    """
    send_slack(summary, context)
    send_teams(summary, context)
