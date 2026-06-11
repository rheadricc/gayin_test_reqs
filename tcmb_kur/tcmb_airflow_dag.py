from datetime import datetime, timedelta
import importlib.util
import os
import sys
import tempfile

import boto3
from airflow import DAG
from airflow.models import Variable
from airflow.operators.python import PythonOperator


S3_BUCKET = "gain-data-airflow-bucket"
SCRIPT_S3_KEY = "python_scripts/tcmb_kur_hesaplama.py"

DEFAULT_ARGS = {
    "owner": "data-team",
    "depends_on_past": False,
    "retries": 1,
    "retry_delay": timedelta(minutes=10),
}


def download_and_import_script(bucket_name: str, s3_key: str, module_name: str):
    s3 = boto3.client("s3")
    temp_dir = tempfile.gettempdir()
    local_file_path = os.path.join(temp_dir, f"{module_name}.py")

    s3.download_file(bucket_name, s3_key, local_file_path)
    print(f"📥 S3'ten TCMB kur script indirildi: {local_file_path}")

    spec = importlib.util.spec_from_file_location(module_name, local_file_path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    spec.loader.exec_module(module)
    return module


def run_tcmb_exchange_rates(mode: str = "daily", **kwargs):
    os.environ.update({
        "TCMB_BASE_URL": Variable.get(
            "TCMB_BASE_URL",
            default_var="https://www.tcmb.gov.tr/kurlar",
        ),
        "TCMB_URL": Variable.get(
            "TCMB_URL",
            default_var="https://www.tcmb.gov.tr/kurlar/today.xml",
        ),

        "DEBUG": "0",
        "API_TIMEOUT_SECONDS": "120",
        "API_MAX_RETRIES": "3",
        "API_RETRY_SLEEP_SECONDS": "5",

        "WRITE_CSV": "0",
        "BQ_ENABLED": "1",
        "BQ_PROJECT_ID": "microgain-9f959",
        "BQ_DATASET": "bc_t",
        "BQ_TABLE": "tcmb_exchange_rates_raw",

        # Tek tablo + rate_date partition yapısı.
        "BQ_TABLE_MODE": "partitioned",
        "BQ_TABLE_PREFIX": "tcmb_exchange_rates",

        "GOOGLE_APPLICATION_CREDENTIALS": Variable.get("GOOGLE_APPLICATION_CREDENTIALS_PATH"),
    })

    module = download_and_import_script(
        bucket_name=S3_BUCKET,
        s3_key=SCRIPT_S3_KEY,
        module_name=f"tcmb_exchange_rates_export_{mode}",
    )

    old_argv = sys.argv[:]
    try:
        sys.argv = ["tcmb_kur_hesaplama.py", mode]
        module.main()
    finally:
        sys.argv = old_argv


with DAG(
    dag_id="tcmb_exchange_rates_daily",
    default_args=DEFAULT_ARGS,
    description="TCMB daily exchange rates load to BigQuery partitioned table",
    start_date=datetime(2026, 5, 1),
    schedule="0 11 * * *",
    catchup=False,
    max_active_runs=1,
    tags=["tcmb", "exchange-rates", "daily", "bigquery"],
) as dag:

    run_tcmb_exchange_rates_task = PythonOperator(
        task_id="run_tcmb_exchange_rates_daily",
        python_callable=run_tcmb_exchange_rates,
        op_kwargs={"mode": "daily"},
    )