from airflow.providers.slack.operators.slack_webhook import SlackWebhookOperator
from airflow.providers.google.cloud.hooks.bigquery import BigQueryHook
from botocore.exceptions import ClientError
from datetime import datetime, timedelta
from google.cloud import bigquery
from urllib.parse import unquote
from datetime import datetime
import boto3, json, logging, time
import re
import os
import requests
import tempfile


# Logger
logger = logging.getLogger(__name__)


TEAMS_WEBHOOK_URL = "https://astav2019.webhook.office.com/webhookb2/2b882404-4032-424d-9fc4-5d4c2e8c84d5@46a5e2a3-6015-4c6c-b96c-eaebfe5b2329/IncomingWebhook/5a2388a0569a43a7a944f184a69635db/fb28b310-977e-4958-8a58-3320ed69daa1/V28Ia8HRdbwvvdZQXU_P5y9rD9HJ14eeviSYnzCFGWSZg1"

# ------------------ Yardımcı Fonksiyonlar ------------------

MAX_MSG_LEN = 450


def _shorten_message(message: str, limit: int = MAX_MSG_LEN) -> str:
    if not message:
        return ""
    message = str(message)
    if len(message) > limit:
        return message[:limit] + "... (truncated)"
    return message

def send_teams_alert(message, context=None):
    dag_id = context['dag'].dag_id if context and 'dag' in context else 'Unknown DAG'
    run_id = context['dag_run'].run_id if context and 'dag_run' in context else 'Unknown Run'
    task_id = context['task_instance'].task_id if context and 'task_instance' in context else 'Unknown Task'

    short_msg = _shorten_message(message)
    full_message = f"[DAG: {dag_id} | Run: {run_id} | Task: {task_id}]\n{short_msg}"

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

    short_msg = _shorten_message(message)
    full_message = f"[DAG: {dag_id} | Run: {run_id} | Task: {task_id}]\n{short_msg}"

    SlackWebhookOperator(
        task_id=f'send_slack_message_{context["task_instance"].try_number}',
        slack_webhook_conn_id='slack_default',
        message=full_message,
        username='airflow_bot',
    ).execute(context=context)
    print(full_message)

def check_s3_path_exists(s3_bucket, s3_key,context):
    s3 = boto3.client('s3')
    try:
        result = s3.list_objects_v2(Bucket=s3_bucket, Prefix=s3_key)
        return 'Contents' in result
    except ClientError as e:
        msg = f"S3 prod_pay_subs path kontrolü sırasında hata oluştu: {str(e)}"
        logger.error(msg)
        send_teams_alert(msg, context)
        send_slack_message(msg, context)
        raise Exception(f"S3 prod_pay_subs path kontrolü sırasında hata oluştu: {str(e)}")

def get_s3_file_count(bucket_name, s3_prefix):
    s3 = boto3.client('s3')
    file_count = 0
    continuation_token = None
    
    # Sayfalama ile dosya sayısını al
    while True:
        list_args = {'Bucket': bucket_name, 'Prefix': s3_prefix}
        
        if continuation_token:
            list_args['ContinuationToken'] = continuation_token
        
        response = s3.list_objects_v2(**list_args)
        
        if 'Contents' in response:
            file_count += len(response['Contents'])
        
        # Eğer daha fazla dosya varsa, bir sonraki sayfayı almak için continuation token'ı kontrol et
        if response.get('IsTruncated'):  # IsTruncated, başka sayfa olup olmadığını belirler
            continuation_token = response.get('NextContinuationToken')
        else:
            break
    
    return file_count

def load_data_to_bigquery_with_operator(json_payloads, bq_dataset_id, bq_table_id, context):

    hook = BigQueryHook(gcp_conn_id="google_cloud_default_full")
    client = hook.get_client()

    table_ref = f"{client.project}.{bq_dataset_id}.{bq_table_id}"
    BATCH_SIZE = 500

    def batch(iterable, size):
        for i in range(0, len(iterable), size):
            yield iterable[i:i + size]

    total_inserted = 0
    for idx, chunk in enumerate(batch(json_payloads, BATCH_SIZE)):
        try:
            errors = client.insert_rows_json(table=table_ref, json_rows=chunk)
            if errors:
                msg = f"❌ BigQuery insert hatası (batch {idx+1}): {errors}"
                logger.error(msg)
                send_teams_alert(msg, context)
                send_slack_message(msg, context)
                raise Exception(msg)
            logger.info(f"✅ Batch {idx+1}: {len(chunk)} kayıt yüklendi.")
            total_inserted += len(chunk)
        except Exception as e:
            msg = f"❌ BigQuery insert sırasında bilinmeyen hata (batch {idx+1}): {str(e)}"
            logger.error(msg)
            send_teams_alert(msg, context)
            send_slack_message(msg, context)
            raise

    logger.info(f"✅ Tüm {total_inserted} kayıt başarıyla BigQuery'ye yüklendi.")

def adjust_json_fields_for_bq(json_data):

    field_map = {
        "subscriptionPlanId": "subscription_plan_id",
        "autoRenewal": "auto_renewal",
        "validUntil": "valid_until",
        "graceUntil": "grace_until",
        "holdUntil": "hold_until",
        "paymentCycleDay": "payment_cycle_day",
        "paymentOption": "payment_option",
        "cardNumber": "card_number",
        "googleOriginalTransactionId": "google_original_transaction_id",
        "amountBeforePromotions": "amount_before_promotions",
        "appliedPromotions": "applied_promotions",
        "appleOriginalTransactionId": "apple_original_transaction_id",
        "freeTrialStartDate": "free_trial_start_date",
        "freeTrialEndDate": "free_trial_end_date",
        "userId": "user_id",
        "registeredAt": "registered_at",
        "createdAt": "created_at",
        "agreements": "agreements",  # Agreements field mapping
        "subscribedClient": "subscribed_client",
    }

    expected_fields = set([
        "status", "subscription_plan_id", "name", "countries", "benefits",
        "auto_renewal", "valid_until", "grace_until", "hold_until", "payment_cycle_day",
        "payment_option", "amount", "currency", "card_number", "google_original_transaction_id",
        "amount_before_promotions", "agreements", "applied_promotions", "apple_original_transaction_id",
        "free_trial_start_date", "free_trial_end_date", "user_id", "email", "registered_at", "created_at",
        "inserted_date","subscribed_client","type"
    ])

    array_fields = {"countries", "applied_promotions", "agreements"}  # Treat these as arrays
    struct_fields = {"benefits"}
    stringified_fields = {}

    adjusted_data = {}

    # Handle missing or empty array fields if they don't exist in the input JSON
    for field in array_fields:
        if field not in json_data:
            if field == "countries":
                adjusted_data[field] = ["UNKNOWN"]  # Placeholder for missing countries array
            elif field == "applied_promotions":
                adjusted_data[field] = [{"promotionId": None, "type": None, "isActive": None, "name": None, "code": None, "applyDate": None, "benefits": [{"isFreePremium": None, "currency": None, "discountPeriod": None, "fixedPrice": None, "freePremiumByDay": None, "freePremiumByMonth": None, "usedPeriod": None}]}]
            elif field == "agreements":
                adjusted_data[field] = [{"id": None, "signedAt": None}]
    
    # Handle nested structs and arrays inside arrays
    def process_nested_array(arr, field_name):
        if isinstance(arr, list):
            if len(arr) == 0:
                # Add "UNKNOWN" placeholder for empty arrays
                if field_name == "countries":
                    return ["UNKNOWN"]
                elif field_name == "applied_promotions":
                    return [{"promotionId": None, "type": None, "isActive": None, "name": None, "code": None, "applyDate": None, "benefits": [{"isFreePremium": None, "currency": None, "discountPeriod": None, "fixedPrice": None, "freePremiumByDay": None, "freePremiumByMonth": None, "usedPeriod": None}]}]
                elif field_name == "agreements":
                    return [{"id": None, "signedAt": None}]
                else:
                    return []
            else:
                # Recursively process nested arrays
                for idx, item in enumerate(arr):
                    if isinstance(item, dict):  # If it's a struct, process it
                        arr[idx] = process_nested_struct(item, field_name)
                return arr
        return arr

    def process_nested_struct(struct, field_name):
        # Recursively process struct fields, adding "null" for missing fields
        for key, value in struct.items():
            if isinstance(value, list):
                struct[key] = process_nested_array(value, key)
            elif value is None:  # For null values in struct, add "null"
                struct[key] = None
        return struct

    # Process each field in the JSON
    for key, value in json_data.items():
        adjusted_key = field_map.get(key, key)

        # Handle the `countries` array separately to add "UNKNOWN" if it's missing or empty
        if adjusted_key == "countries":
            if adjusted_key not in json_data or not json_data[adjusted_key]:
                adjusted_data[adjusted_key] = ["UNKNOWN"]
            else:
                adjusted_data[adjusted_key] = process_nested_array(value, adjusted_key)
        elif adjusted_key in array_fields:
            if adjusted_key == "applied_promotions":
                # Handling applied_promotions field (which might contain nested structures)
                if isinstance(value, list):
                    adjusted_data[adjusted_key] = process_nested_array(value, adjusted_key)
            elif adjusted_key == "agreements":
                # Handle agreements field (array of structs, might be empty)
                if isinstance(value, list):
                    adjusted_data[adjusted_key] = process_nested_array(value, adjusted_key)
            else:
                adjusted_data[adjusted_key] = value if isinstance(value, list) and len(value) > 0 else []

        # Handle struct fields (empty struct handling)
        elif adjusted_key in struct_fields:
            adjusted_data[adjusted_key] = value if isinstance(value, dict) and len(value) > 0 else {}

        # Handle other stringified fields (like agreements, which is array of objects)
        elif adjusted_key in stringified_fields:
            adjusted_data[adjusted_key] = json.dumps(value) if value else None

        else:
            # For null or missing fields, insert "null" if expected
            if value is None:
                adjusted_data[adjusted_key] = None
            else:
                adjusted_data[adjusted_key] = value

    # Ensure that all expected fields are included, set missing fields to None or "UNKNOWN"
    for col in expected_fields:
        adjusted_data.setdefault(col, None)

    return adjusted_data

def move_to_fail_path(bucket_name, file_name, fail_base_path, **context):
    s3 = boto3.client('s3')

    try:
        file_path = unquote(file_name.replace('s3://', '').lstrip('/'))
        file_path = file_path.replace(' ', '')
        file_name = os.path.basename(file_path)

        match = re.search(r'success/(\d{4})/(\d{2})/(\d{2})/(\d{2})/(.+)', file_path)
        if not match:
            raise ValueError(f"Test_Gain_Subs_Pay_S3_To_Bq, dosya ismi beklenen formatta değil: {file_name}")

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

        logger.warning(f"❗ Test_Gain_Subs_Pay_S3_To_Bq, Dosya fail klasörüne taşındı: {fail_path}")

    except Exception as e:
        msg = f"❌ Test_Gain_Subs_Pay_S3_To_Bq, Fail klasörüne taşıma hatası: {file_name}\nHata: {e}"
        logger.error(msg)
        send_teams_alert(msg, context)
        send_slack_message(msg, context)

# ------------------ Ana Task Fonksiyonu ------------------

def check_and_load_data_to_bq(bucket_name, fail_base_path, **context):
    execution_date = context['execution_date']
    target_time = execution_date
    s3_path = target_time.strftime('success/%Y/%m/%d/%H/')
    inserted_date = (execution_date + timedelta(hours=1)).strftime('%Y-%m-%d %H:%M:%S')

    bq_hook = BigQueryHook(gcp_conn_id="google_cloud_default_full")
    bq_client = bq_hook.get_client()

    dataset_id = "test_dataset"
    table_id = "subs_payment_test"
    full_table_id = f"{bq_client.project}.{dataset_id}.{table_id}"

    delete_query = f"""DELETE FROM `{full_table_id}`
    WHERE inserted_date >= TIMESTAMP('{(target_time + timedelta(hours=1)).isoformat()}')
    AND inserted_date < TIMESTAMP('{(target_time + timedelta(hours=2)).isoformat()}')"""

    try:
        logger.info(f"🧹 Eski veriler siliniyor: {delete_query}")
        bq_hook.run_query(sql=delete_query, use_legacy_sql=False)
        logger.info("✅ Eski veriler başarıyla silindi.")
    except Exception as e:        
        msg = f"❌ BigQuery DELETE hatası: {e}"
        logger.error(msg)
        send_teams_alert(msg, context)
        send_slack_message(msg, context)
        raise

    s3_file_count = get_s3_file_count(bucket_name, s3_path)
    logger.info(f"📦 S3'teki dosya sayısı (tüm uzantılar dahil): {s3_file_count}")

    s3 = boto3.client('s3')
    contents = []
    continuation_token = None

    while True:
        list_kwargs = {
            'Bucket': bucket_name,
            'Prefix': s3_path,
            'MaxKeys': 1000,
        }
        if continuation_token:
            list_kwargs['ContinuationToken'] = continuation_token

        response = s3.list_objects_v2(**list_kwargs)

        if "Contents" in response:
            contents.extend(response["Contents"])

        if response.get("IsTruncated"):
            continuation_token = response.get("NextContinuationToken")
        else:
            break

    if not contents:
        logger.info(f"{s3_path} içinde dosya bulunamadı!")
        return

    json_payloads = []
    file_key_list = []
    skipped_files = []
    parse_failed_files = []

    MAX_RETRIES = 3
    json_file_count = 0

    for obj in contents:
        file_key = obj["Key"]

        if not file_key.endswith(".json"):
            skipped_files.append(file_key)
            continue

        json_file_count += 1

        try:
            for attempt in range(MAX_RETRIES):
                try:
                    file_obj = s3.get_object(Bucket=bucket_name, Key=file_key)
                    break
                except Exception as e:
                    logger.warning(f"⚠️ S3 get_object denemesi {attempt + 1}/{MAX_RETRIES} başarısız: {e}")
                    time.sleep(2 * (attempt + 1))
                    if attempt == MAX_RETRIES - 1:
                        raise

            file_content = file_obj["Body"].read().decode("utf-8")
            json_data = json.loads(file_content)
            json_data["inserted_date"] = inserted_date

            adjusted_data = adjust_json_fields_for_bq(json_data)
            json_payloads.append(adjusted_data)
            file_key_list.append(file_key)

        except Exception as e:
            parse_failed_files.append(file_key)

            msg = f"❌ JSON Parse hatası: {file_key} - {e}"
            logger.error(msg)
            send_teams_alert(msg, context)
            send_slack_message(msg, context)

            try:
                move_to_fail_path(bucket_name, file_key, fail_base_path, **context)
            except Exception as move_err:
                logger.error(f"❌ move_to_fail_path hatası: {file_key} taşınamadı! Hata: {move_err}")

    # İşlenen dosya ve istatistik log'ları
    logger.info(f"📁 Toplam .json dosya sayısı: {json_file_count}")
    logger.info(f"📁 Başarıyla işlenen dosya sayısı: {len(file_key_list)}")
    logger.info(f"📁 Uzantısı .json olmayan atlanan dosya sayısı: {len(skipped_files)}")
    logger.info(f"❌ Parse edilemeyen dosya sayısı: {len(parse_failed_files)}")

    if skipped_files:
        logger.info(f"🔕 Atlanan dosyalar örnekleri: {skipped_files[:5]}")
    if parse_failed_files:
        logger.info(f"🧨 Parse hatası alan dosyalar örnekleri: {parse_failed_files[:5]}")

    total_handled = len(file_key_list) + len(skipped_files) + len(parse_failed_files)
    if total_handled < s3_file_count:
        logger.warning(f"⚠️ Tüm S3 dosyaları işlenmedi! S3: {s3_file_count}, İşlenen + Atlanan + Parse failed: {total_handled}")

    if not json_payloads:
        logger.warning("⚠️ Yüklenecek veri bulunamadı!")
        return

    load_data_to_bigquery_with_operator(json_payloads, dataset_id, table_id, context)
    logger.info(f"✅ Tüm {len(json_payloads)} kayıt başarıyla yüklendi.")
