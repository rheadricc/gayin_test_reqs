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


logger = logging.getLogger(__name__)

# S3 ayarları
S3_BUCKET = "gain-data-airflow-bucket"
S3_KEY = "airflow_keys/token_store.json"
s3_client = boto3.client('s3')

REFRESH_URL = "https://api.gain.tv/2da7kf8jf/TOKEN/refresh?__culture=tr-tr"
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

def fix_column_name(col_name):
    col_name = col_name.strip().lower()
    col_name = re.sub(r'\s+', '_', col_name)
    col_name = re.sub(r'[^\w]+', '_', col_name)
    col_name = re.sub(r'_+', '_', col_name)
    col_name = col_name.strip('_')
    if col_name and col_name[0].isdigit():
        col_name = f"prefix_{col_name}"
    return col_name

def deep_serialize(val):
    try:
        if isinstance(val, list):
            if not val or all(isinstance(i, str) and i.strip() == '' for i in val):
                return None
        if isinstance(val, dict) and not val:
            return None
        if isinstance(val, str) and val.strip() == '':
            return None
        if pd.isna(val):
            return None
        if isinstance(val, (list, dict)):
            return json.dumps(val, ensure_ascii=False)
        return json.dumps([val], ensure_ascii=False)
    except Exception:
        return str(val)

def serialize_nested_columns(df, nested_columns):
    for col in nested_columns:
        if col in df.columns:
            df[col] = df[col].apply(lambda x: deep_serialize(x) if x is not None else None)
    return df

def clean_numeric_columns(df, cols):
    for col in cols:
        if col in df.columns:
            df[col] = df[col].apply(lambda x: None if x == '' else x)
            df[col] = pd.to_numeric(df[col], errors='coerce')
    return df         

def fetch_and_insert_titles(context):
    try:
        refresh_token(context)
        hook = BigQueryHook(gcp_conn_id="google_cloud_default_full")
        client = hook.get_client()

        title_list_url = "https://api.gain.tv/2da7kf8jf/CALL/Title/getTitleListForBo/default?__culture=tr-tr"
        title_detail_url = "https://api.gain.tv/2da7kf8jf/CALL/Title/getTitleDetailForBo/{}?__culture=tr-tr"

        def get_all_title_ids(context, retry_count=3, timeout=60, retry_delay=10):
            try:
                title_ids = []
                index = 0

                while True:
                    attempt = 0
                    while attempt < retry_count:
                        try:
                            params = {
                                "query": "*",
                                "from": index,
                                "pageSize": 50,
                                "sorts": [{"createdAt": "desc"}]
                            }

                            response = requests.post(title_list_url, headers=get_otp_headers(context), json=params, timeout=timeout)

                            if response.status_code == 200:
                                page_data = response.json().get('result', [])
                                if not page_data:
                                    logger.info(f"Toplam {len(title_ids)} adet titleId bulundu.")
                                    return title_ids

                                for title in page_data:
                                    title_ids.append(title.get('titleId'))

                                index += 50
                                break
                            else:
                                logger.warning(f"❗️Title ID çekme başarısız (status {response.status_code})")
                                attempt += 1
                                time.sleep(retry_delay)

                        except Exception as e:
                            attempt += 1
                            if attempt == retry_count:
                                msg = f"❌ Title ID çekme hatası: {e}"
                                logger.error(msg)
                                send_teams_alert(msg, context)
                                send_slack_message(msg, context)
                                raise
                            else:
                                logger.warning(f"⏳ Deneme {attempt}/{retry_count} (get_all_title_ids) başarısız. {retry_delay}s sonra tekrar denenecek...")
                                time.sleep(retry_delay)

            except Exception as e:
                msg = f"get_all_title_ids genel hata: {e}"
                logger.error(msg)
                send_teams_alert(msg, context)
                send_slack_message(msg, context)
                raise

        def get_title_details(title_id, context, retry_count=3, timeout=60, retry_delay=10):
            attempt = 0
            while attempt < retry_count:
                try:
                    url = title_detail_url.format(title_id)
                    response = requests.get(url, headers=get_otp_headers(context), timeout=timeout)

                    if response.status_code == 200:
                        data = response.json().get('title', {})                    

                        title_data = {
                            "titleId": data.get("titleId", ""),
                            "displayName": data.get("displayName", ""),
                            "type": data.get("type", ""),
                            "geoBlocking": data.get("geoBlocking", ""),
                            "contentType_id": data.get("contentType", {}).get("id", ""),
                            "imdbScore": data.get("imdbScore", ""),
                            "publishYear": data.get("publishYear", ""),
                            "searchKeywords": data.get("searchKeywords", ""),
                            "description_tr": data.get("description", {}).get("tr-tr", ""),
                            "shortDescription_tr": data.get("shortDescription", {}).get("tr-tr", ""),
                            "isGainOriginal": data.get("isGainOriginal", ""),
                            "tags": [{"id": tag.get("id", ""), "name": tag.get("name", "")} for tag in data.get("tags", [])],
                            "artists": [{"id": artist.get("id", ""), "text": artist.get("text", "")} for artist in data.get("artists", [])],
                            "genres": [{"id": genre.get("id", ""), "name": genre.get("name", "")} for genre in data.get("genres", [])],
                            "directors": [{"id": director.get("id", ""), "text": director.get("text", "")} for director in data.get("directors", [])],
                            "smartSigns": [{"id": ss.get("id", ""), "name": ss.get("name", "")} for ss in data.get("smartSigns", [])]
                        }

                        season_rows = []
                        for season in data.get("seasons", []):
                            video_contents = []
                            for video_content in season.get("videoContents", []):
                                vc_entry = {
                                    "videoContentId": video_content.get("videoContentId", ""),
                                    "name.tr-tr": video_content.get("name", {}).get("tr-tr", ""),
                                    "shortName.tr-tr": video_content.get("shortName", {}).get("tr-tr", ""),
                                    "type": video_content.get("type", ""),
                                    "countryInfo": []
                                }

                                for country_info in video_content.get("countryInfo", []):
                                    ci_entry = {
                                        "smartSigns": [
                                            {"id": ss.get("id", ""), "name": ss.get("name", "")}
                                            for ss in country_info.get("smartSigns", [])
                                        ],
                                        "media": {
                                            "duration": country_info.get("media", {}).get("duration", "")
                                        }
                                    }
                                    vc_entry["countryInfo"].append(ci_entry)

                                video_contents.append(vc_entry)

                            sezon_bilgisi = season.get("name", {}).get("tr-tr", "")
                            season_row = title_data.copy()
                            season_row.update({
                                "seasons": season.get("seasonId", ""),
                                "season_info": sezon_bilgisi,
                                "videoContents": video_contents
                            })

                            season_rows.append(season_row)

                        return season_rows
                    else:
                        logger.info(f"Detay alınamadı: {title_id}, Status code: {response.status_code}")
                        return []


                except Exception as e:
                    attempt += 1
                    if attempt == retry_count:
                        msg = f"❌ Detay çekme hatası ({title_id}): {e}"
                        logger.error(msg)
                        send_teams_alert(msg, context)
                        send_slack_message(msg, context)
                        return []
                    else:
                        logger.warning(f"⏳ Deneme {attempt}/{retry_count} ({title_id}) başarısız. {retry_delay}s sonra tekrar denenecek...")
                        time.sleep(retry_delay)

            return []

        # 🔄 Title ID ve Detayları çek
        title_ids = get_all_title_ids(context)
        all_rows = []
        for tid in title_ids:
            all_rows.extend(get_title_details(tid, context))

        if not all_rows:
            logger.info("Hiç veri alınamadı.")
            return

        df = pd.DataFrame(all_rows)
        df.columns = [fix_column_name(col) for col in df.columns]

        # 📌 1. Nested kolonları JSON'a çevir
        nested_cols = [
            "tags", "artists", "genres", "directors",
            "smartsigns", "videocontents", "countryinfo",
            "geoblocking", "searchkeywords"
        ]
        df = serialize_nested_columns(df, nested_cols)

        # 📌 2. Boş string'leri None yap (global tüm dataframe için)
        df = df.applymap(lambda x: None if isinstance(x, str) and x.strip() == '' else x)

        # 📌 3. Sayısal kolonları düzelt
        numeric_cols = ["publishyear", "imdbscore"]
        df = clean_numeric_columns(df, numeric_cols)

        # 🎯 BigQuery'ye yükle
        table_id = "microgain-9f959.Backoffice_metadata.bo_titles"
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
        msg = f"Ana akışta hata oluştu: {e}"
        logger.error(msg)
        send_teams_alert(msg, context)
        send_slack_message(msg, context)
        raise