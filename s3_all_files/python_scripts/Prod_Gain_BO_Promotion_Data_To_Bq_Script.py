import pandas as pd
import requests
import tempfile
import logging
import boto3
import uuid
import json
import time
import os
import re
from airflow.providers.slack.operators.slack_webhook import SlackWebhookOperator
from airflow.providers.google.cloud.hooks.bigquery import BigQueryHook
from botocore.exceptions import ClientError
from google.cloud import bigquery

# LOGGING
logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)

# S3 ve token ayarları
S3_BUCKET = "gain-data-airflow-bucket"
S3_KEY = "airflow_keys/token_store.json"
REFRESH_URL = "https://api.gain.tv/2da7kf8jf/TOKEN/refresh?__culture=tr-tr"
s3_client = boto3.client("s3")

                     
PROMOTION_LIST_URL = "https://api.gain.tv/2da7kf8jf/CALL/Promotion/getPromotionList/default"
PROMOTION_DETAIL_URL = "https://api.gain.tv/2da7kf8jf/CALL/Promotion/getPromotion/{}?__culture=tr-tr"
TEAMS_WEBHOOK_URL = "https://astav2019.webhook.office.com/webhookb2/2b882404-4032-424d-9fc4-5d4c2e8c84d5@46a5e2a3-6015-4c6c-b96c-eaebfe5b2329/IncomingWebhook/73bbcc514fc341a6b7d09ea60d4363fa/fb28b310-977e-4958-8a58-3320ed69daa1/V2TdHAX8_h2YMiKZT9rlCPzMCmCStWxZvYEHVMtUU0zPg1"

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

def load_tokens(context):
    try:
        response = s3_client.get_object(Bucket=S3_BUCKET, Key=S3_KEY)
        return json.loads(response["Body"].read().decode("utf-8"))
    except ClientError as e:
        if e.response["Error"]["Code"] == "NoSuchKey":
            return {"accessToken": "", "refreshToken": ""}
        else:
            logger.error(f"S3'ten token okunamadı: {e}")
            raise
    except Exception as e:
        msg = f"Token yükleme hatası: {e}"
        logger.error(msg)
        send_teams_alert(msg, context)
        send_slack_message(msg, context)
        raise

def save_tokens(tokens, context):
    try:
        s3_client.put_object(
            Bucket=S3_BUCKET,
            Key=S3_KEY,
            Body=json.dumps(tokens),
            ContentType="application/json"
        )
    except Exception as e:
        msg = f"Token kaydetme hatası: {e}"
        logger.error(msg)
        send_teams_alert(msg, context)
        send_slack_message(msg, context)
        raise

def refresh_token(context):
    try:
        tokens = load_tokens(context)
        current_refresh_token = tokens.get("refreshToken")

        if not current_refresh_token:
            raise ValueError("Refresh token bulunamadı.")

        headers = {"Content-Type": "application/json"}
        body = {"refreshToken": current_refresh_token}

        response = requests.post(REFRESH_URL, headers=headers, json=body)

        if response.status_code == 200:
            new_tokens = response.json()
            save_tokens({
                "accessToken": new_tokens["accessToken"],
                "refreshToken": new_tokens["refreshToken"]
            }, context)
            logger.info("Token yenilendi.")
            return new_tokens["accessToken"]
        else:
            raise Exception(f"Token yenileme başarısız: {response.status_code}, {response.text}")
    except Exception as e:
        msg = f"Refresh token hatası: {e}"
        logger.error(msg)
        send_teams_alert(msg, context)
        send_slack_message(msg, context)
        raise

def get_otp_headers(context):
    try:
        tokens = load_tokens(context)
        return {
            "Content-Type": "application/json",
            "User-Agent": "Python/requests",
            "Authorization": f"Bearer {tokens['accessToken']}"
        }
    except Exception as e:
        msg = f"Header oluşturulamadı: {e}"
        logger.error(msg)
        send_teams_alert(msg, context)
        send_slack_message(msg, context)
        raise

def get_all_promotion_ids(context):
    all_promotions = []
    page = 0
    page_size = 50

    while True:
        payload = {
            "query": "isActive:true",
            "from": page * page_size,
            "pageSize": page_size,
            "sorts": [{"createdAt": "desc"}]
        }

        try:
            headers = get_otp_headers(context)
            response = requests.post(PROMOTION_LIST_URL, headers=headers, json=payload)
            response.raise_for_status()
            result = response.json().get("result", [])
            if not result:
                break
            for promotion in result:
                promotion_id = promotion.get("promotionId")
                if promotion_id:
                    all_promotions.append(promotion_id)
            page += 1
        except Exception as e:
            msg = f"Promotion list çekilemedi: {e}"
            logger.error(msg)
            send_teams_alert(msg, context)
            send_slack_message(msg, context)
            raise

    return all_promotions


def get_detailed_promotions(promotion_ids, context):
    all_data = []

    try:
        headers = get_otp_headers(context={})
        for pid in promotion_ids:
            url = PROMOTION_DETAIL_URL.format(pid)
            payload = {
                "query": "isActive:true",
                "from": 0,
                "pageSize": 10,
                "sorts": [{"createdAt": "desc"}]
            }
            response = requests.post(url, headers=headers, json=payload)
            if response.status_code == 200:
                promotion = response.json()
                promotion_data = {
                    "promotionId": promotion.get("promotionId", ""),
                    "name": promotion.get("name", "").strip(),
                    "type": promotion.get("type", ""),
                    "isActive": promotion.get("isActive", False),
                    "countries": json.dumps(promotion.get("countries", [])),
                    "paymentOptions": json.dumps(promotion.get("paymentOptions", [])),
                    "campaignStartDate": promotion.get("campaignStartDate", ""),
                    "campaignEndDate": promotion.get("campaignEndDate", ""),
                    "codeCount": promotion.get("codeCount", 0),
                    "maxUsageCount": promotion.get("maxUsageCount", 0),
                    "usageCount": promotion.get("usageCount", 0),
                    "createdBy": promotion.get("createdBy", ""),
                    "createdAt": promotion.get("createdAt", ""),
                    "benefits": json.dumps(promotion.get("benefits", [])),
                    "generatedCodeCount": promotion.get("generatedCodeCount", 0),
                    "promotionCompany": promotion.get("promotionCompany", ""),
                    "promotionDescription": promotion.get("promotionDescription", ""),
                    "assignedTo": json.dumps(promotion.get("assignedTo", []))
                }
                all_data.append(promotion_data)
                #logger.info(f"✔ Promotion alındı: {pid}")
            else:
                logger.warning(f"❌ Hata ({response.status_code}) - ID: {pid}, response: {response.text}")
    
    except Exception as e:
        msg = f"Detay veriler alınırken hata oluştu: {e}"
        logger.error(msg)
        send_teams_alert(msg, context)
        send_slack_message(msg, context)
        raise

    return all_data


def get_all_detailed_promotion_data_and_insert_bq(context):
    try:
        promotion_ids = get_all_promotion_ids(context)
        data = get_detailed_promotions(promotion_ids, context)
        df = pd.DataFrame(data)

        if df.empty:
            msg = "📭 Promotion verisi alınamadı. BigQuery'ye yükleme atlandı."
            logger.warning(msg)
            send_teams_alert(msg, context)
            send_slack_message(msg, context)
            return

        hook = BigQueryHook(gcp_conn_id="google_cloud_default_full")
        client = hook.get_client()

          # 🎯 BigQuery'ye yükle        
        table_id = "microgain-9f959.Backoffice_metadata.bo_promotions"
        job = client.load_table_from_dataframe(
            df,
            table_id,
            job_config=bigquery.LoadJobConfig(
                write_disposition="WRITE_TRUNCATE",
                autodetect=True
            )
        )
        job.result()
        logger.info(f"📊 BigQuery'ye {len(df)} satır yollandı.")
        
    except Exception as e:
        msg = f"BigQuery yükleme hatası: {e}"
        logger.error(msg)
        send_teams_alert(msg, context)
        send_slack_message(msg, context)
        raise

