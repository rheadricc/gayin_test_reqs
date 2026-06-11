from airflow.providers.slack.operators.slack_webhook import SlackWebhookOperator
from airflow.providers.google.cloud.hooks.bigquery import BigQueryHook
from botocore.exceptions import ClientError
from airflow.hooks.base import BaseHook
from jinja2 import Template
import pandas as pd
import requests
import logging
import json
import math
import boto3

logger = logging.getLogger(__name__)


TEAMS_WEBHOOK_URL = "https://astav2019.webhook.office.com/webhookb2/2b882404-4032-424d-9fc4-5d4c2e8c84d5@46a5e2a3-6015-4c6c-b96c-eaebfe5b2329/IncomingWebhook/5a2388a0569a43a7a944f184a69635db/fb28b310-977e-4958-8a58-3320ed69daa1/V28Ia8HRdbwvvdZQXU_P5y9rD9HJ14eeviSYnzCFGWSZg1"

# ------------------ Yardımcı Fonksiyonlar ------------------

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

# S3 connection and get sql script
def get_sql_script_from_s3(key):
    s3 = boto3.client('s3')
    bucket_name = 'gain-data-airflow-bucket'
    try:
        return s3.get_object(Bucket=bucket_name, Key=key)['Body'].read().decode('utf-8')
    except ClientError as e:
        msg = f"S3 {key} path kontrolü sırasında hata oluştu: {str(e)}"
        logger.error(msg)
        raise Exception(msg)

def render_sql_from_s3(key, execution_date):
    sql = get_sql_script_from_s3(key)
    template = Template(sql)
    return template.render(ds=execution_date.strftime('%Y-%m-%d'))

def get_insider_connection_info():
    conn = BaseHook.get_connection("insider_prod")
    headers = conn.extra_dejson.get("headers", {})  # Burada sadece sabit olanlar kalacak
    headers["Content-Type"] = "application/json"
    headers["X-REQUEST-TOKEN"] = conn.password  # 👈 token buradan güvenli şekilde geliyor
    host = conn.host
    return host, headers

def delete_existing_data(**kwargs):
    hook = BigQueryHook(gcp_conn_id="google_cloud_default_full", use_legacy_sql=False)
    execution_date = kwargs['execution_date']
    execution_date_str = execution_date.strftime('%Y-%m-%d')

    try:
        delete_sql = f"""
            DELETE FROM `microgain-9f959.insider.insider_upsert_api_daily`
            WHERE DATE(etl_date) = DATE('{execution_date_str}')
        """
        hook.run(sql=delete_sql)
        logger.info(f"🧹 {execution_date_str} tarihli eski veriler silindi.")
    except Exception as e:
        msg = f"❌ BigQuery'de {execution_date_str} için veri silinirken hata oluştu: {str(e)}"
        logger.error(msg)
        send_teams_alert(msg, kwargs)
        send_slack_message(msg, kwargs)
        raise

def get_updated_users_from_bq(**kwargs):
    try:
        hook = BigQueryHook(gcp_conn_id="google_cloud_default_full", use_legacy_sql=False)
        sql = render_sql_from_s3(
            'sql_scripts/Insider_sql/Prod_Gain_Insider_Daily_Upsert_Api_Get_Updated_User_Data.sql',
            kwargs['execution_date']
        )
        df = hook.get_pandas_df(sql=sql)
        logger.info(f"✅ BigQuery'den {len(df)} kayıt alındı.")
        return df
    except Exception as e:
        msg = f"BigQuery verisi alınırken hata oluştu: {str(e)}"
        logger.error(msg)
        send_teams_alert(msg, kwargs)
        send_slack_message(msg, kwargs)
        raise

def execute_daily_custom_user_attributes_sql(**kwargs):
    try:
        hook = BigQueryHook(gcp_conn_id="google_cloud_default_full", use_legacy_sql=False)
        sql = render_sql_from_s3(
            'sql_scripts/Insider_sql/Prod_Gain_Insider_Daily_Upsert_Api_Custom_User_Attributes_Data.sql',
            kwargs['execution_date']
        )
        hook.run(sql=sql)
        logger.info("📊 Custom user attribute SQL başarıyla çalıştırıldı.")
    except Exception as e:
        msg = f"Custom user attribute SQL çalıştırılırken hata oluştu: {str(e)}"
        logger.error(msg)
        send_teams_alert(msg, kwargs)
        send_slack_message(msg, kwargs)
        raise

def send_users_to_insider(**context):
    try:
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

    except Exception as e:
        msg = f"Insider'a veri gönderiminde hata oluştu: {str(e)}"
        logger.error(msg)
        send_teams_alert(msg, context)
        send_slack_message(msg, context)
        raise