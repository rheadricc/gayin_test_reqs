from datetime import datetime, timedelta
import asyncio
import importlib.util
import os
import sys
import tempfile

import boto3
from airflow import DAG
from airflow.operators.python import PythonOperator


DAG_ID = "gain_multi_profile_counter"
S3_BUCKET = "gain-data-airflow-bucket"
SCRIPT_S3_KEY = "python_scripts/bo_all_profiles_count.py"


def download_and_import_function(bucket_name: str, s3_key: str, module_name: str = "bo_all_profiles_count"):
    s3 = boto3.client("s3")
    temp_dir = tempfile.gettempdir()
    local_file_path = os.path.join(temp_dir, f"{module_name}.py")

    s3.download_file(bucket_name, s3_key, local_file_path)
    print(f"📥 S3'ten multi profile counter script indirildi: {local_file_path}")

    spec = importlib.util.spec_from_file_location(module_name, local_file_path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    spec.loader.exec_module(module)
    return module


def run_multi_profile_counter_callable(**kwargs):
    # Script prod MWAA tarafında S3 token store kullanacak.
    # AUTH_TOKEN özellikle set edilmiyor; token_store.json içindeki accessToken kullanılacak.
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

        "GOOGLE_APPLICATION_CREDENTIALS": "{{ var.value.GOOGLE_APPLICATION_CREDENTIALS_PATH }}",
    })

    module = download_and_import_function(
        bucket_name=S3_BUCKET,
        s3_key=SCRIPT_S3_KEY,
    )

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
        provide_context=True,
    )