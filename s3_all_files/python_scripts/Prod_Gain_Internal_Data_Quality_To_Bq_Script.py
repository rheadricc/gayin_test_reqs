import logging
import boto3
import requests
from google.cloud import bigquery
from airflow.providers.google.cloud.hooks.bigquery import BigQueryHook

logger = logging.getLogger(__name__)
TEAMS_WEBHOOK_URL = "https://astav2019.webhook.office.com/webhookb2/2b882404-4032-424d-9fc4-5d4c2e8c84d5@46a5e2a3-6015-4c6c-b96c-eaebfe5b2329/IncomingWebhook/cf978585d1d04fcb97b85219823238ea/73e5ebec-a145-4531-90e0-e7ccc90f9410/V2TpKPDvZJjm7YxTq5yP3HHjIGxTReNOko0QTdXUsdKI01"  # senin URL'in burada kalmalı

def send_teams_alert(message, context=None):
    context = context or {}
    dag_id = context.get('dag', {}).dag_id if 'dag' in context else 'Unknown DAG'
    run_id = context.get('dag_run', {}).run_id if 'dag_run' in context else 'Unknown Run'
    task_id = context.get('task_instance', {}).task_id if 'task_instance' in context else 'Unknown Task'
    full_message = f"[DAG: {dag_id} | Run: {run_id} | Task: {task_id}]\n{message}"

    payload = {"text": full_message}
    headers = {"Content-Type": "application/json"}
    try:
        response = requests.post(TEAMS_WEBHOOK_URL, headers=headers, json=payload)
        response.raise_for_status()
        logger.info("✅ Teams mesajı gönderildi!")
    except requests.exceptions.RequestException as e:
        logger.error(f"❌ Teams mesajı gönderilemedi: {e}")

def get_sql_script_from_s3(key):
    s3 = boto3.client("s3")
    bucket_name = "gain-data-airflow-bucket"
    content = s3.get_object(Bucket=bucket_name, Key=key)["Body"].read().decode("utf-8")
    return content

def run_sql_from_s3(key: str, client: bigquery.Client, params: list = None, context: dict = None):
    try:
        sql = get_sql_script_from_s3(key)
        logger.info(f"📄 Yüklenen SQL dosyası: {key}")
        logger.debug(f"SQL içeriği:\n{sql}")

        job_config = bigquery.QueryJobConfig(
            query_parameters=params or [],
            use_legacy_sql=False
        )
        query_job = client.query(sql, job_config=job_config)
        rows = list(query_job)

        logger.info(f"✅ SQL başarıyla çalıştı: {key}")
        logger.info(f"📊 Toplam hata kaydı: {len(rows)}")

        if rows:
            # 🔁 Tüm hataları logla
            for i, row in enumerate(rows):
                logger.warning(f"⚠️ {key} → [{i+1}] Hata: {row}")

            # Teams mesajı için sadece ilk N satır
            MAX_ROWS_TEAMS = 20
            preview_rows = rows[:MAX_ROWS_TEAMS]
            preview_text = "\n".join([str(row) for row in preview_rows])

            more_rows_count = len(rows) - MAX_ROWS_TEAMS
            extra_note = f"\n...ve {more_rows_count} kayıt daha. Tüm detaylar Airflow loglarında." if more_rows_count > 0 else ""

            message = (
                f"📌 *{key}* sorgusu çalıştırıldı.\n"
                f"🔎 *{len(rows)}* hata kaydı bulundu.\n"
                f"🧾 İlk {len(preview_rows)} kayıt:\n```{preview_text}```{extra_note}"
            )

            send_teams_alert(message, context=context)

        logger.info("-" * 100)

    except Exception as e:
        logger.error(f"❌ Hata (SQL: {key}): {str(e)}")
        send_teams_alert(f"❌ Hata oluştu: {key} → {str(e)}", context=context)
        raise



def execute_data_quality_checks(etl_date, context=None):
    logger.info(f"🎯 Parametre geçilen etl_date: {etl_date}")
    bq_hook = BigQueryHook(gcp_conn_id="google_cloud_default_full")
    client = bq_hook.get_client(project_id="microgain-9f959")

    params = [bigquery.ScalarQueryParameter("etl_date", "DATE", str(etl_date))]

    sql_paths = [
        "sql_scripts/data_quality_sql/user_core_validations.sql",
        "sql_scripts/data_quality_sql/user_date_consistency_checks.sql",
        "sql_scripts/data_quality_sql/user_subscription_promotion_rules.sql",
    ]

    for key in sql_paths:
        run_sql_from_s3(key=key, client=client, params=params, context=context)

def execute_user_actions_quality_check(etl_date, context=None):
    logger.info(f"🚀 user_actions tablosu için quality check başlatıldı. etl_date={etl_date}")
    bq_hook = BigQueryHook(gcp_conn_id="google_cloud_default_full")
    client = bq_hook.get_client(project_id="microgain-9f959")

    params = [bigquery.ScalarQueryParameter("etl_date", "DATE", str(etl_date))]

    run_sql_from_s3(
        key="sql_scripts/data_quality_sql/user_actions_data_quality_check.sql",
        client=client,
        params=params,
        context=context
    )

def execute_iys_quality_check(etl_date, context=None):
    logger.info(f"🚀 iys_subs tablosu için quality check başlatıldı. etl_date={etl_date}")
    bq_hook = BigQueryHook(gcp_conn_id="google_cloud_default_full")
    client = bq_hook.get_client(project_id="microgain-9f959")
    params = [bigquery.ScalarQueryParameter("etl_date", "DATE", str(etl_date))]
    run_sql_from_s3(
        key="sql_scripts/data_quality_sql/iys_data_quality_check.sql",
        client=client,
        params=params,
        context=context
    )


def execute_data_quality_checks_from_context(**kwargs):
    execution_date = kwargs["execution_date"]
    etl_date = execution_date.date()  # Airflow execution_date zaten T-1 verir
    execute_data_quality_checks(etl_date=etl_date, context=kwargs)
