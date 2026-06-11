import logging
from elasticsearch import Elasticsearch
from pandas_gbq import to_gbq
from datetime import datetime, timedelta
from airflow.providers.google.cloud.hooks.bigquery import BigQueryHook
import requests
from airflow.hooks.base import BaseHook
import pandas as pd
from google.cloud import bigquery
import boto3

logger = logging.getLogger(__name__)

TEAMS_WEBHOOK_URL = "https://astav2019.webhook.office.com/webhookb2/2b882404-4032-424d-9fc4-5d4c2e8c84d5@46a5e2a3-6015-4c6c-b96c-eaebfe5b2329/IncomingWebhook/5a44d3afe0cc419b99a5f223f2f42c8c/95cc1d9a-876c-4566-add7-e62cee46926b/V2IO3p9Dft06nFTeAHJJwHm2X4srP976IWwPXvknDLVlk1"

logging.getLogger("elasticsearch").setLevel(logging.WARNING)

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

def fetch_dim_user_raw_and_push_bq(**kwargs):
    context = kwargs
    try:
        execution_date = kwargs["execution_date"]

        if isinstance(execution_date, str):
            execution_date = pd.to_datetime(execution_date)
        elif hasattr(execution_date, "to_datetime_string"):
            execution_date = pd.to_datetime(str(execution_date))
        elif not isinstance(execution_date, (datetime, pd.Timestamp)):
            raise ValueError(f"Unexpected execution_date type: {type(execution_date)}")

        etl_date = execution_date.date()

        start_ts = pd.to_datetime(f"{etl_date}T00:00:00Z")
        end_ts = pd.to_datetime(f"{etl_date + timedelta(days=1)}T00:00:00Z")

        logger.info(f"📅 ETL date range: {start_ts} → {end_ts} (UTC)")

        # Elasticsearch bağlantısı
        conn = BaseHook.get_connection("elasticsearch_default")
        cloud_id = conn.extra_dejson.get("cloud_id")
        es = Elasticsearch(cloud_id=cloud_id, basic_auth=(conn.login, conn.password))

        query = {
            "bool": {
                "should": [
                    {"range": {"updatedAt": {"gte": start_ts.isoformat(), "lt": end_ts.isoformat()}}},
                    {"range": {"createdAt": {"gte": start_ts.isoformat(), "lt": end_ts.isoformat()}}}
                ],
                "minimum_should_match": 1
            }
        }

        index_name = "gain_2da7kf8jf_prod_user"
        scroll_size = 1000
        res = es.search(index=index_name, scroll='2m', size=scroll_size, query=query)
        scroll_id = res['_scroll_id']
        hits = res['hits']['hits']
        all_docs = [hit['_source'] for hit in hits]

        while hits:
            res = es.scroll(scroll_id=scroll_id, scroll='2m')
            hits = res['hits']['hits']
            if not hits:
                break
            all_docs.extend([hit['_source'] for hit in hits])

        if not all_docs:
            logger.warning("⚠️ Elasticsearch verisi bulunamadı.")
            send_teams_alert("⚠️ Elasticsearch verisi bulunamadı.", context)
            raise ValueError("No data from Elasticsearch.")

        # DataFrame'e çevir
        df = pd.DataFrame(all_docs)

        # === appliedApplicationForms: list → STRING ===
        import json
        if "appliedApplicationForms" not in df.columns:
            df["appliedApplicationForms"] = None

        def _array_to_str(x):
            if isinstance(x, list):
                return json.dumps(x, ensure_ascii=False)
            if x is None or (isinstance(x, float) and pd.isna(x)):
                return None
            return str(x)

        df["appliedApplicationForms"] = df["appliedApplicationForms"].apply(_array_to_str)
        # ===========================================================

        # Tarih alanları (top-level)
        df["etl_date"] = pd.to_datetime(etl_date)
        df["createdAt"] = pd.to_datetime(df["createdAt"], utc=True, errors="coerce") \
                            .dt.tz_localize(None).dt.strftime("%Y-%m-%d %H:%M:%S")
        df["updatedAt"] = pd.to_datetime(df["updatedAt"], utc=True, errors="coerce") \
                            .dt.tz_localize(None).dt.strftime("%Y-%m-%d %H:%M:%S")
        df_filtered = df[pd.to_datetime(df["updatedAt"], errors="coerce").dt.date == etl_date].copy()

        logger.info(f"🧽 Final DataFrame shape: {df_filtered.shape}")
        logger.info("🔍 createdAt distribution:")
        logger.info(df_filtered["createdAt"].str[:10].value_counts().sort_index())
        logger.info("🔍 updatedAt distribution:")
        logger.info(df_filtered["updatedAt"].str[:10].value_counts().sort_index())

        # BigQuery işlemleri
        bq_project = "microgain-9f959"
        bq_table = "gain_model_prod.prod_dim_user_raw"
        bq_hook = BigQueryHook(gcp_conn_id="google_cloud_default_full")
        credentials = bq_hook.get_credentials()
        client = bq_hook.get_client(project_id=bq_project)

        # Mevcut etl_date verisini sil
        delete_sql = """
        DELETE FROM `microgain-9f959.gain_model_prod.prod_dim_user_raw`
        WHERE DATE(etl_date) = @etl_date
        """
        delete_job = client.query(delete_sql, job_config=bigquery.QueryJobConfig(
            query_parameters=[bigquery.ScalarQueryParameter("etl_date", "DATE", str(etl_date))],
            use_legacy_sql=False
        ))
        delete_job.result()
        logger.info(f"🧹 Eski kayıtlar silindi: {etl_date}")

        # Yeni verileri insert et (schema parametresi YOK)
        to_gbq(
            df_filtered,
            destination_table=bq_table,
            project_id=bq_project,
            if_exists="append",
            credentials=credentials
        )
        logger.info(f"✅ {len(df_filtered)} kayıt başarıyla yüklendi (ETL date = {etl_date})")

        execute_sql_steps(etl_date=etl_date, context=context)

    except Exception as e:
        logger.exception("🔥 fetch_dim_user_raw_and_push_bq failed")
        send_teams_alert(f"🔥 Hata oluştu: {str(e)}", context=context)
        raise


def get_sql_script_from_s3(key):
    s3 = boto3.client('s3')
    bucket_name = 'gain-data-airflow-bucket'
    return s3.get_object(Bucket=bucket_name, Key=key)['Body'].read().decode('utf-8')


def run_sql_from_s3(key: str, client: bigquery.Client, params: list = None):
    try:
        sql = get_sql_script_from_s3(key)
        logger.info(f"📄 S3'ten SQL script yüklendi: {key}")
        logger.debug(f"SQL içeriği:\n{sql}")

        job_config = bigquery.QueryJobConfig(
            query_parameters=params or [],
            use_legacy_sql=False
        )

        query_job = client.query(sql, job_config=job_config)
        query_job.result()
        logger.info(f"✅ SQL script başarıyla çalıştırıldı: {key}")
    except Exception as e:
        logger.error(f"❌ SQL script çalıştırma hatası ({key}): {str(e)}")
        raise


def execute_sql_steps(etl_date: datetime.date, context: dict):
    bq_hook = BigQueryHook(gcp_conn_id="google_cloud_default_full")
    client = bq_hook.get_client(project_id="microgain-9f959")

    params = [bigquery.ScalarQueryParameter("etl_date", "DATE", str(etl_date))]

    sql_execution_plan = [
        ("sql_scripts/elastic_sql/Prod_Gain_Elastic_Select_All_User_Data.sql", "STAGE TABLE OLUŞTURMA"),
        ("sql_scripts/elastic_sql/Prod_Gain_Elastic_Update_All_User_Data.sql", "MEVCUT VERİYİ PASİFLEŞTİRME"),
        ("sql_scripts/elastic_sql/Prod_Gain_Elastic_Insert_All_User_Data.sql", "YENİ VERSİYONLARI EKLEME"),
    ]

    for key, description in sql_execution_plan:
        try:
            logger.info(f"▶ SQL Adımı başlatılıyor: {description} ({key})")
            run_sql_from_s3(key=key, client=client, params=params)
            logger.info(f"✅ SQL Adımı tamamlandı: {description}")
        except Exception as e:
            logger.error(f"❌ {description} sırasında hata oluştu — {str(e)}")
            send_teams_alert(f"❌ {description} sırasında hata oluştu: {str(e)}", context=context)
            raise
