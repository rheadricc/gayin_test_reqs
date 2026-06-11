from airflow.providers.amazon.aws.transfers.s3_to_redshift import S3ToRedshiftOperator
from airflow.providers.postgres.operators.postgres import PostgresOperator
from airflow.providers.slack.operators.slack_webhook import SlackWebhookOperator
from airflow import DAG
from airflow.operators.python import PythonOperator
from datetime import datetime, timedelta
import boto3
from urllib.parse import unquote
import re
import os
from botocore.exceptions import ClientError
import requests
import json


default_args = {
    'owner': 'airflow',
    'depends_on_past': False,
    'start_date': datetime(2025, 1, 3, 10),
    'retries': 1,
    'retry_delay': timedelta(minutes=5),
}


TEAMS_WEBHOOK_URL = "https://astav2019.webhook.office.com/webhookb2/2b882404-4032-424d-9fc4-5d4c2e8c84d5@46a5e2a3-6015-4c6c-b96c-eaebfe5b2329/IncomingWebhook/5a44d3afe0cc419b99a5f223f2f42c8c/95cc1d9a-876c-4566-add7-e62cee46926b/V2IO3p9Dft06nFTeAHJJwHm2X4srP976IWwPXvknDLVlk1"  # Teams Webhook URL'sini buraya ekle
def send_teams_alert(message):
    """Microsoft Teams kanalına hata mesajı gönderir."""
    payload = {"text": message}
    headers = {"Content-Type": "application/json"}

    try:
        response = requests.post(TEAMS_WEBHOOK_URL, headers=headers, json=payload)
        response.raise_for_status()
        print("✅ Teams mesajı başarıyla gönderildi!")
    except requests.exceptions.RequestException as e:
        print(f"❌ Teams mesajı gönderilirken hata oluştu: {e}")

def send_slack_message(message, context):
    SlackWebhookOperator(
        task_id='send_slack_message',
        slack_webhook_conn_id='slack_default',
        message=message,
        username='airflow_bot',
    ).execute(context=context)
    print(message)

def check_s3_path_exists(s3_bucket, s3_key):
    s3 = boto3.client('s3')
    try:
        result = s3.list_objects_v2(Bucket=s3_bucket, Prefix=s3_key)
        return 'Contents' in result
    except ClientError as e:
        raise Exception(f"S3 path kontrolü sırasında hata oluştu: {str(e)}")

def move_to_fail_path(bucket_name, file_name, fail_base_path, **context):
    s3 = boto3.client('s3')

    try:
        file_path = unquote(file_name.replace('s3://', '').lstrip('/'))
        file_path = file_path.replace(' ', '')
        file_name = os.path.basename(file_path)

        match = re.search(r'success/(\d{4})/(\d{2})/(\d{2})/(\d{2})/(.+)', file_path)
        if not match:
            raise ValueError(f"Dosya ismi beklenen formatta değil: {file_name}")

        year, month, day, hour, file = match.groups()
        fail_path = f"{fail_base_path}/success/{year}/{month}/{day}/{hour}/{file}"
        source_path = f"success/{year}/{month}/{day}/{hour}/{file}"

        # Dosyayı yeni konuma kopyala
        s3.copy_object(
            Bucket=bucket_name,
            CopySource={'Bucket': bucket_name, 'Key': source_path},
            Key=fail_path
        )

        # Orijinal dosyayı sil
        s3.delete_object(Bucket=bucket_name, Key=source_path)

        print(f"Dosya başarıyla taşındı: {fail_path}")

    except Exception as e:
        print(f"Fail path'e taşıma sırasında hata oluştu: {str(e)}")

def handle_failed_load(bucket_name, fail_base_path, **context):
    
    now = datetime.utcnow()
    current_hour = now.replace(minute=0, second=0, microsecond=0)

    query = f"""
        SELECT file_name
        FROM sys_load_error_detail
        WHERE database_name = 'dev'
        AND table_id = 229749
        AND start_time >= '{current_hour.strftime('%Y-%m-%d %H:%M:%S')}'
        AND start_time < '{(current_hour + timedelta(hours=1)).strftime('%Y-%m-%d %H:%M:%S')}';
    """
    print(query)
    
    task_id = "get_failed_files"
    postgres_task = PostgresOperator(
        task_id=task_id,
        sql=query,
        postgres_conn_id='Redshift_Serverless_Test',
        autocommit=True,  # Autocommit aktif, çünkü sadece sorgu çalıştıracağız
        database='dev',
    )
    
    # Sorgu sonuçlarını alalım ve hatalı dosyaları taşıyalım
    failed_files = postgres_task.execute(context=context)
    
    if not failed_files:
        print("Hatalı dosya bulunamadı.")
        return

    # Hatalı dosyaların her birini fail path'e taşıyoruz
    for file in failed_files:
        file_name = file[0]  # 'file_name' kolonunun değeri
        print(f"Hatalı dosya bulundu: {file_name}")
        move_to_fail_path(bucket_name, file_name, fail_base_path, **context)

def check_and_load_data(bucket_name, fail_base_path, **context):
    # execution_date'i UTC olarak al
    execution_date = context['execution_date']

    # Bir önceki saati al
    target_time = execution_date
    s3_path = target_time.strftime('success/%Y/%m/%d/%H/')

    while True:

        try:
            if check_s3_path_exists(bucket_name, s3_path):
                load_s3_to_redshift = S3ToRedshiftOperator(
                    task_id='load_s3_to_redshift',
                    schema='public',
                    table='subs_payment_test',
                    s3_bucket=bucket_name,
                    s3_key=s3_path,
                    copy_options=["FORMAT AS JSON 's3://gain-test-bucket-1/subscription_data_json_pathfile.json'", "TIMEFORMAT 'auto'",],
                    aws_conn_id='aws_default',
                    redshift_conn_id='Redshift_Serverless_Test',
                    method='APPEND',
                )
                load_s3_to_redshift.execute(context=context)
                message = f"S3 path {s3_path} bulundu ve veri Redshift'e yüklendi."
                print(message)
                break

            else:
                message = f"S3 path {s3_path} bulunamadı! Bu saat için veri yok."
                print(message)
                break

        except Exception as e:
            
            message = f"Test-Subs-Payment verisi yükleme sırasında hata oluştu: {str(e)}"
            print(message)
            send_slack_message(message, context)
            # STL_LOAD_ERRORS tablosundan hatalı dosyayı tespit et ve fail path'e taşı
            print("Hatalı dosya tespit ediliyor...")
            
            error_message = (
                f"🚨 *HATA*: Redshift'e dosya yüklenirken hata oluştu!\n"
                f"📌 *Dosya*: `{fail_base_path}`\n"
                f"📌 *Hata*: ```{str(e)}```\n"
                f"📌 *DAG*: `{context.get('dag').dag_id}`\n"
                f"📌 *Task*: `{context.get('task').task_id}`\n"
                f"📌 *Tarih*: `{context.get('execution_date')}`"
            )
            print(error_message)
            send_teams_alert(error_message)  # Hata mesajını Teams'e gönder
            handle_failed_load(bucket_name, fail_base_path, **context)

with DAG(
    'test-subs-pay-dag',
    default_args=default_args,
    description='Transfer data from S3 to Redshift',
    schedule_interval='@hourly',
    catchup=False,
) as dag:

    bucket_name = 'gain-data-pay-subs'
    fail_base_path = 'copy_fail_files'  # Fail path prefix

    delete_old_data_task = PostgresOperator(
        task_id='delete_old_data_task',
        postgres_conn_id='Redshift_Serverless_Test',
        sql="""
        DELETE FROM public.subs_payment_test
        WHERE inserted_date >= '{{ (execution_date + macros.timedelta(hours=1)).replace(tzinfo=None).strftime('%Y-%m-%d %H:%M:%S') }}'
        AND inserted_date < '{{ (next_execution_date + macros.timedelta(hours=1)).replace(tzinfo=None).strftime('%Y-%m-%d %H:%M:%S') }}';
        """,
    )

    check_and_load_data_task = PythonOperator(
        task_id='check_and_load_data_task',
        python_callable=check_and_load_data,
        op_kwargs={
            'bucket_name': bucket_name,
            'fail_base_path': fail_base_path,
        },
        provide_context=True,
    )

    update_inserted_date_task = PostgresOperator(
        task_id='update_inserted_date_task',
        postgres_conn_id='Redshift_Serverless_Test',
        sql="""
        UPDATE public.subs_payment_test
        SET inserted_date = '{{ (execution_date + macros.timedelta(hours=1, seconds=30)).replace(tzinfo=None).strftime('%Y-%m-%d %H:%M:%S') }}'
        WHERE inserted_date IS NULL;
        """,
    )

    delete_old_data_task >> check_and_load_data_task >> update_inserted_date_task