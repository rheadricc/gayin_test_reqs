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
SCRIPT_S3_KEY = "python_scripts/paynkolay.py"

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
    print(f"📥 S3'ten N Kolay / Paynkolay script indirildi: {local_file_path}")

    spec = importlib.util.spec_from_file_location(module_name, local_file_path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    spec.loader.exec_module(module)
    return module


def run_nkolay_transactions(mode: str, **kwargs):
    os.environ.update({
        "NKOLAY_BASE_URL": Variable.get("NKOLAY_BASE_URL"),
        "NKOLAY_LIST_SX": Variable.get("NKOLAY_LIST_SX"),
        "NKOLAY_MERCHANT_SECRET_KEY": Variable.get("NKOLAY_MERCHANT_SECRET_KEY"),

        "DEBUG": "0",
        "API_TIMEOUT_SECONDS": "120",
        "API_MAX_RETRIES": "3",
        "API_RETRY_SLEEP_SECONDS": "5",

        "WRITE_CSV": "0",
        "BQ_ENABLED": "1",
        "BQ_PROJECT_ID": "microgain-9f959",
        "BQ_DATASET": "bc_t",
        "BQ_TABLE": "nkolay_transactions_raw",

        "GOOGLE_APPLICATION_CREDENTIALS": Variable.get("GOOGLE_APPLICATION_CREDENTIALS_PATH"),
    })

    module = download_and_import_script(
        bucket_name=S3_BUCKET,
        s3_key=SCRIPT_S3_KEY,
        module_name=f"nkolay_transactions_export_{mode}",
    )

    old_argv = sys.argv[:]
    try:
        sys.argv = ["paynkolay.py", mode]
        module.main()
    finally:
        sys.argv = old_argv


def create_nkolay_dag(dag_id, mode, schedule, description):
    with DAG(
        dag_id=dag_id,
        default_args=DEFAULT_ARGS,
        description=description,
        start_date=datetime(2026, 5, 1),
        schedule=schedule,
        catchup=False,
        max_active_runs=1,
        tags=["nkolay", "paynkolay", "transactions", mode, "bigquery"],
    ) as dag:

        PythonOperator(
            task_id=f"run_nkolay_transactions_{mode}",
            python_callable=run_nkolay_transactions,
            op_kwargs={"mode": mode},
        )

        return dag


nkolay_transactions_daily = create_nkolay_dag(
    dag_id="nkolay_transactions_daily",
    mode="daily",
    schedule="0 7 * * *",
    description="N Kolay / Paynkolay T-1 daily transactions load to BigQuery",
)


nkolay_transactions_monthly = create_nkolay_dag(
    dag_id="nkolay_transactions_monthly",
    mode="monthly",
    schedule="0 6 2 * *",
    description="N Kolay / Paynkolay previous month transactions load to BigQuery",
)


nkolay_transactions_manual = create_nkolay_dag(
    dag_id="nkolay_transactions_manual",
    mode="manual",
    schedule=None,
    description="N Kolay / Paynkolay month-to-date manual transactions load to BigQuery",
)