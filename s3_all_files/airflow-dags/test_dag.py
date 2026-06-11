from airflow.providers.google.cloud.hooks.bigquery import BigQueryHook
from airflow.operators.python import PythonOperator
from datetime import datetime, timedelta
from airflow.hooks.base import BaseHook
from google.cloud import bigquery
from jinja2 import Template
from airflow import DAG
import pandas as pd
import requests
import logging
import json
import math
import boto3

logger = logging.getLogger(__name__)

# S3 connection and get sql script
def get_sql_script_from_s3(key):
    s3 = boto3.client('s3')
    bucket_name = 'gain-data-airflow-bucket'
    return s3.get_object(Bucket=bucket_name, Key=key)['Body'].read().decode('utf-8')

def render_sql_from_s3(key, execution_date):
    sql = get_sql_script_from_s3(key)
    template = Template(sql)
    return template.render(ds=execution_date.strftime('%Y-%m-%d'))


def get_insider_connection_info():
    conn = BaseHook.get_connection("insider_uat")
    headers = conn.extra_dejson.get("headers", {})  # Burada sadece sabit olanlar kalacak
    headers["Content-Type"] = "application/json"
    headers["X-REQUEST-TOKEN"] = conn.password  # 👈 token buradan güvenli şekilde geliyor
    host = conn.host
    return host, headers

def delete_existing_data(**kwargs):
    hook = BigQueryHook(gcp_conn_id="google_cloud_default_full", use_legacy_sql=False)
    execution_date = kwargs['execution_date']
    execution_date_str = execution_date.strftime('%Y-%m-%d')
    
    delete_sql = f"""
        DELETE FROM `microgain-9f959.insider.insider_upsert_api_daily`
        WHERE DATE(etl_date) = DATE('{execution_date_str}')
    """
    hook.run(sql=delete_sql)
    logger.info(f"🧹 {execution_date_str} tarihli eski veriler silindi.")

def get_updated_users_from_bq(**kwargs):
    hook = BigQueryHook(gcp_conn_id="google_cloud_default_full", use_legacy_sql=False)
    sql = render_sql_from_s3(
        'sql_scripts/Insider_sql/Prod_Gain_Insider_Daily_Upsert_Api_Get_Updated_User_Data.sql',
        kwargs['execution_date']
    )
    df = hook.get_pandas_df(sql=sql)
    logger.info(f"✅ BigQuery'den {len(df)} kayıt alındı.")
    return df


def execute_daily_custom_user_attributes_sql(**kwargs):
    hook = BigQueryHook(gcp_conn_id="google_cloud_default_full", use_legacy_sql=False)
    sql = render_sql_from_s3(
        'sql_scripts/Insider_sql/Prod_Gain_Insider_Daily_Upsert_Api_Custom_User_Attributes_Data.sql',
        kwargs['execution_date']
    )
    hook.run(sql=sql)
    logger.info("📊 Prod_Gain_Insider_Daily_Upsert_Api_Custom_User_Attributes_Data SQL script executed.")

def send_users_to_insider(**context):
    df = get_updated_users_from_bq(**context)
    host, headers = get_insider_connection_info()
    endpoint = f"{host}/api/user/v1/upsert"
    batch_size = 500
    num_batches = math.ceil(len(df) / batch_size)

    total_success = 0
    total_fail = 0

    for i in range(num_batches):
        batch = df.iloc[i * batch_size: (i + 1) * batch_size]
        payload = {
            "skip_hook": False,
            "users": []
        }

        for _, row in batch.iterrows():
            if not row["email_address"] and not row["uuid"]:
                continue

            user_payload = {
                "identifiers": {
                    "uuid": row["uuid"],
                    "email": row["email_address"]
                },
                "attributes": {
                    "custom": {
                        "subscription": bool(row["subscription"]) if pd.notnull(row["subscription"]) else None,
                        "cancel_request_date": pd.to_datetime(row["cancel_request_date"]).strftime('%Y-%m-%dT%H:%M:%SZ') if pd.notnull(row["cancel_request_date"]) else None,
                        "free_trial": bool(row["free_trial"]) if pd.notnull(row["free_trial"]) else None,
                        "churn_date": pd.to_datetime(row["churn_date"]).strftime('%Y-%m-%dT%H:%M:%SZ') if pd.notnull(row["churn_date"]) else None,
                        "signup_date": pd.to_datetime(row["signup_date"]).strftime('%Y-%m-%dT%H:%M:%SZ') if pd.notnull(row["signup_date"]) else None,
                        "is_email_permitted": bool(row["isEmailPermitted"]) if pd.notnull(row["isEmailPermitted"]) else None
                    }
                }
            }
            payload["users"].append(user_payload)

        response = requests.post(endpoint, headers=headers, json=payload)
        if response.status_code == 200:
            result = response.json()
            total_success += result.get("data", {}).get("successful", {}).get("count", 0)
            total_fail += result.get("data", {}).get("fail", {}).get("count", 0)
        else:
            logger.error(f"❌ Batch {i + 1} FAILED - Status: {response.status_code}, Message: {response.text}")

    logger.info(f"📦 Toplam başarılı kullanıcı sayısı: {total_success}")
    logger.info(f"📉 Toplam başarısız kullanıcı sayısı: {total_fail}")
    context['ti'].xcom_push(key='total_sent', value=total_success)

default_args = {
    'owner': 'airflow',
    'depends_on_past': False,
    'start_date': datetime(2025, 5, 10),
    'retries': 1,
    'retry_delay': timedelta(minutes=5),
}

dag = DAG(
    'Daily_Insider_User_Data_Upsert_Test_Dag',
    default_args=default_args,
    description='Sent user data from BQ to insider uat environement as daily.',
    schedule_interval='@daily',
    catchup=False,
    tags=['UPSERT API', 'INSIDER'],
    max_active_runs=1
)

delete_existing_data_task = PythonOperator(
    task_id='delete_existing_data_task',
    python_callable=delete_existing_data,
    provide_context=True,
    dag=dag
)

execute_user_attribute_sql_task = PythonOperator(
    task_id='execute_daily_custom_user_attributes_sql_task',
    python_callable=execute_daily_custom_user_attributes_sql,
    provide_context=True,
    dag=dag
)

send_updated_user_data_to_upsert_api_task = PythonOperator(
    task_id='send_users_to_insider_with_upsert_api_task',
    python_callable=send_users_to_insider,
    provide_context=True,
    dag=dag
)

delete_existing_data_task >> execute_user_attribute_sql_task >> send_updated_user_data_to_upsert_api_task

