from datetime import datetime, timedelta
import asyncio
import importlib.util
import os
import sys
import tempfile

import boto3
from airflow import DAG
from airflow.operators.python import PythonOperator
from airflow.providers.google.cloud.hooks.bigquery import BigQueryHook
from google.cloud import bigquery


DAG_ID = "gain_kids_profile_full_scan"
S3_BUCKET = "gain-data-airflow-bucket"
SCRIPT_S3_KEY = "python_scripts/kids_async_identifier.py"


def patch_bigquery_client(module, gcp_conn_id: str = "google_cloud_default"):
    """Make downloaded scripts use Airflow's existing GCP connection instead of a local key file."""
    if not hasattr(module, "bigquery"):
        return

    hook = BigQueryHook(gcp_conn_id=gcp_conn_id)
    credentials = hook.get_credentials()
    connection_project_id = hook.project_id or "microgain-9f959"
    original_client = bigquery.Client

    def airflow_bigquery_client(*args, **kwargs):
        project = kwargs.get("project") or connection_project_id
        return original_client(credentials=credentials, project=project)

    module.bigquery.Client = airflow_bigquery_client


def download_and_import_function(bucket_name: str, s3_key: str, module_name: str = "kids_async_identifier"):
    s3 = boto3.client("s3")
    temp_dir = tempfile.gettempdir()
    local_file_path = os.path.join(temp_dir, f"{module_name}.py")

    s3.download_file(bucket_name, s3_key, local_file_path)
    print(f"📥 S3'ten kids script indirildi: {local_file_path}")

    spec = importlib.util.spec_from_file_location(module_name, local_file_path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    spec.loader.exec_module(module)
    return module


def run_kids_profile_scan_callable(**kwargs):
    # Script prod MWAA tarafında S3 token store kullanacak.
    # AUTH_TOKEN özellikle set edilmiyor; token_store.json içindeki accessToken kullanılacak.
    os.environ.update({
        "PROD_BASE_URL": "https://api.gain.tv/2da7kf8jf",

        "PAGE_SIZE": "100",
        "MAX_PAGES": "0",
        "MAX_WORKERS": "35",
        "ENABLE_TQDM": "0",

        "PAUSE_EVERY_PAGES": "50",
        "PAUSE_SECONDS": "10",

        "SCAN_MODE": "full",
        "DATE_FIELD": "updatedAt",
        "LOOKBACK_DAYS": "2",

        "TOKEN_STORE_MODE": "s3",
        "S3_BUCKET": S3_BUCKET,
        "S3_TOKEN_KEY": "airflow_keys/token_store.json",
        "REFRESH_URL": "https://api.gain.tv/2da7kf8jf/TOKEN/refresh?__culture=tr-tr",
    })

    module = download_and_import_function(
        bucket_name=S3_BUCKET,
        s3_key=SCRIPT_S3_KEY,
    )
    patch_bigquery_client(module)

    asyncio.run(module.main())


default_args = {
    "owner": "data",
    "depends_on_past": False,
    "retries": 1,
    "retry_delay": timedelta(minutes=10),
}

with DAG(
    dag_id=DAG_ID,
    default_args=default_args,
    description="Scan active/in_grace/on_hold users from BO API and update kids profile state in BigQuery",
    start_date=datetime(2026, 5, 13),
    schedule_interval="0 2 * * *",
    catchup=False,
    max_active_runs=1,
    tags=["gain", "backoffice", "kids", "bigquery"],
) as dag:

    run_kids_profile_scan = PythonOperator(
        task_id="run_kids_profile_scan",
        python_callable=run_kids_profile_scan_callable,
        provide_context=True,
    )