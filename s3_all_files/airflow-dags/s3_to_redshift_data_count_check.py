from airflow.providers.postgres.operators.postgres import PostgresOperator
from airflow.operators.python import PythonOperator
from airflow.providers.slack.operators.slack_webhook import SlackWebhookOperator
from airflow import DAG
from datetime import datetime, timedelta
import boto3
import requests
import json

default_args = {
    'owner': 'airflow',
    'depends_on_past': False,
    'start_date': datetime(2025, 1, 6),
    'retries': 1,
    'retry_delay': timedelta(minutes=5),
}

TEAMS_WEBHOOK_URL = "https://astav2019.webhook.office.com/webhookb2/2b882404-4032-424d-9fc4-5d4c2e8c84d5@46a5e2a3-6015-4c6c-b96c-eaebfe5b2329/IncomingWebhook/5a44d3afe0cc419b99a5f223f2f42c8c/95cc1d9a-876c-4566-add7-e62cee46926b/V2IO3p9Dft06nFTeAHJJwHm2X4srP976IWwPXvknDLVlk1"


def send_teams_alert(message):
    """Microsoft Teams kanalına hata mesajı gönderir."""
    payload = {"text": message}
    headers = {"Content-Type": "application/json"}
    response = requests.post(TEAMS_WEBHOOK_URL, headers=headers, json=payload)

    if response.status_code != 200:
        raise Exception(
            f"❌ Teams mesajı gönderilemedi! Hata Kodu: {response.status_code}, Hata Mesajı: {response.text}")

    print("✅ Teams mesajı başarıyla gönderildi!")


def count_s3_objects(bucket_name, prefix):
    s3 = boto3.client('s3')
    count = 0
    paginator = s3.get_paginator('list_objects_v2')
    for page in paginator.paginate(Bucket=bucket_name, Prefix=prefix):
        if 'Contents' in page:
            count += len(page['Contents'])
    return count


def flatten_redshift_count(raw_count):
    """Her türlü nested yapıyı flatten eder: [tuple], [(x,)], ([x],), [[x]] vs."""
    try:
        if isinstance(raw_count, (list, tuple)) and len(raw_count) > 0:
            first = raw_count[0]

            # Eğer first yine list veya tuple ise, onun da ilk elemanını al
            if isinstance(first, (list, tuple)) and len(first) > 0:
                return int(first[0])

            # Eğer first doğrudan int ise
            elif isinstance(first, int):
                return first

        # Eğer hiçbiri değilse, düz int gibi davran
        return int(raw_count)

    except Exception as e:
        print(f"❌ flatten_redshift_count hatası: {e}, gelen değer: {raw_count}")
        return None

def compare_counts(bucket_name, date, ti, slack_conn_id):
    date = datetime.strptime(date, '%Y-%m-%d').date()
    s3_prefix = f"success/{date.strftime('%Y/%m/%d/')}"
    s3_count = count_s3_objects(bucket_name, s3_prefix)

    # Redshift count'u düzgünce parse et
    raw_redshift_count = ti.xcom_pull(task_ids='count_redshift_records')
    redshift_count = flatten_redshift_count(raw_redshift_count)

    if redshift_count is None:
        message = f"❌ Redshift kayıt sayısı alınamadı veya hatalı format: {raw_redshift_count}"
        send_teams_alert(message)
        raise ValueError(message)

    if s3_count != redshift_count:
        message = (f"⚠️ UYARI: {date} tarihli verilerde uyuşmazlık var!\n"
                   f"S3 dosya sayısı: {s3_count}\n"
                   f"Redshift kayıt sayısı: {redshift_count}")
        SlackWebhookOperator(
            task_id='data_integrity_alert',
            slack_webhook_conn_id=slack_conn_id,
            message=message,
            username='airflow_bot',
        ).execute(context={})
        send_teams_alert(message)
    else:
        print(f"✅ Veriler eşleşiyor: S3 = {s3_count}, Redshift = {redshift_count}")


with DAG(
    'prod_subs_payment_data_validation',
    default_args=default_args,
    description='Validate data consistency between S3 and Redshift',
    schedule_interval='5 1 * * *',
    catchup=False,
) as dag:

    bucket_name = 'gain-data-prod-pay-subs'

    count_redshift_records = PostgresOperator(
        task_id='count_redshift_records',
        postgres_conn_id='Redshift_Serverless_Prod_User',
        sql="""
        SELECT COUNT(*) AS record_count
        FROM int_transaction.subs_payment
        WHERE inserted_date BETWEEN '{{ ds }} 01:00:00' AND '{{ next_ds }} 01:00:00';
        """,
        do_xcom_push=True,
    )

    validate_data_counts = PythonOperator(
        task_id='validate_data_counts',
        python_callable=compare_counts,
        op_kwargs={
            'bucket_name': bucket_name,
            'date': '{{ ds }}',
            'slack_conn_id': 'slack_default',
        },
        provide_context=True,
    )

    count_redshift_records >> validate_data_counts
