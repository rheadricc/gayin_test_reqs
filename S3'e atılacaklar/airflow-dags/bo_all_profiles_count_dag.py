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
from slack_callbacks import notify_failure, notify_success


DAG_ID = "gain_profile_counter"
S3_BUCKET = "gain-data-airflow-bucket"
SCRIPT_S3_KEY = "python_scripts/bo_all_profiles_count.py"
GCP_CONN_ID = "google_cloud_default"


def patch_bigquery_client(module, gcp_conn_id: str = GCP_CONN_ID):
    """Make the downloaded script use Airflow's existing Google connection for BigQuery."""
    if not hasattr(module, "bigquery") or module.bigquery is None:
        print("[BQ PATCH WARNING] Downloaded module has no usable bigquery import; patch skipped.")
        return

    hook = BigQueryHook(gcp_conn_id=gcp_conn_id)
    credentials = hook.get_credentials()
    connection_project_id = hook.project_id or "microgain-9f959"
    original_client = bigquery.Client

    def airflow_bigquery_client(*args, **kwargs):
        project = kwargs.get("project") or connection_project_id
        return original_client(credentials=credentials, project=project)

    module.bigquery.Client = airflow_bigquery_client
    print(f"[BQ PATCH] bigquery.Client Airflow connection ile patchlendi: {gcp_conn_id}")


def download_and_import_function(bucket_name: str, s3_key: str, module_name: str = "bo_all_profiles_count"):
    s3 = boto3.client("s3")
    temp_dir = tempfile.gettempdir()
    local_file_path = os.path.join(temp_dir, f"{module_name}.py")

    s3.download_file(bucket_name, s3_key, local_file_path)
    print(f"📥 S3'ten multi profile counter script indirildi: {local_file_path}")
    print(f"[SCRIPT SOURCE] s3://{bucket_name}/{s3_key}")

    spec = importlib.util.spec_from_file_location(module_name, local_file_path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    spec.loader.exec_module(module)
    return module


def run_multi_profile_counter_callable(**kwargs):
    # Script prod MWAA tarafında S3 token store kullanacak.
    # AUTH_TOKEN özellikle set edilmiyor; token_store.json içindeki accessToken kullanılacak.
    # GOOGLE_APPLICATION_CREDENTIALS özellikle set edilmiyor; BigQuery auth Airflow google_cloud_default üzerinden patchleniyor.
    os.environ.update({
        "PROD_BASE_URL": "https://api.gain.tv/2da7kf8jf",

        "TOKEN_STORE_MODE": "s3",
        "S3_BUCKET": S3_BUCKET,
        "S3_TOKEN_KEY": "airflow_keys/token_store.json",

        "USE_BIGQUERY_TARGET_USERS": "1",
        "BQ_PROJECT_ID": "microgain-9f959",
        "USER_VALID_UNTIL_LOOKBACK_DAYS": "90",
        "BQ_MAX_USERS": "0",
        "BQ_TARGET_USERS_SQL": "",

        "PAGE_SIZE": "100",
        "MAX_PAGES": "0",
        "MAX_WORKERS": "100",
        "MAX_RETRIES": "3",

        "SAVE_RESULT_TO_BIGQUERY": "1",
        "BQ_RESULT_TABLE": "microgain-9f959.bc_t.multi_profile_counter",

        "PROFILE_CREATED_AFTER": "",
        "FILTER_USER_VALID_UNTIL_IN_PYTHON": "0",
        "USER_LIST_QUERY": "",
        "TIMEZONE": "Europe/Istanbul",
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
    description="Count total profiles and multi-profile accounts from BO API using BigQuery target users",
    start_date=datetime(2026, 6, 12),
    schedule_interval="5 3 * * *",
    catchup=False,
    max_active_runs=1,
    tags=["gain", "backoffice", "profiles", "bigquery"],
) as dag:

    run_multi_profile_counter = PythonOperator(
        task_id="run_multi_profile_counter",
        python_callable=run_multi_profile_counter_callable,
        on_success_callback=notify_success,
        on_failure_callback=notify_failure,
    )
