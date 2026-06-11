from datetime import datetime, timedelta
import importlib.util
import os
import sys
import tempfile

import boto3
from airflow import DAG
from airflow.models import Variable
from airflow.operators.python import PythonOperator
from airflow.providers.google.cloud.hooks.bigquery import BigQueryHook
from google.cloud import bigquery


S3_BUCKET = "gain-data-airflow-bucket"
SCRIPT_S3_KEY = "python_scripts/payguru.py"

DEFAULT_ARGS = {
    "owner": "data-team",
    "depends_on_past": False,
    "retries": 1,
    "retry_delay": timedelta(minutes=10),
}


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


def download_and_import_script(bucket_name: str, s3_key: str, module_name: str):
    s3 = boto3.client("s3")
    temp_dir = tempfile.gettempdir()
    local_file_path = os.path.join(temp_dir, f"{module_name}.py")

    s3.download_file(bucket_name, s3_key, local_file_path)
    print(f"📥 S3'ten Payguru script indirildi: {local_file_path}")

    spec = importlib.util.spec_from_file_location(module_name, local_file_path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    spec.loader.exec_module(module)
    return module


def run_payguru_transactions(mode: str, **kwargs):
    os.environ.update({
        "PAYGURU_PRODUCT": Variable.get("PAYGURU_PRODUCT", default_var="mp"),
        "PAYGURU_BASE_URL": Variable.get("PAYGURU_BASE_URL", default_var="http://api.trend-tech.net"),
        "PAYGURU_MERCHANT_ID": Variable.get("PAYGURU_MERCHANT_ID"),
        "PAYGURU_SERVICE_IDS": Variable.get("PAYGURU_SERVICE_IDS"),

        "DEBUG": "0",
        "API_TIMEOUT_SECONDS": "120",
        "API_MAX_RETRIES": "3",
        "API_RETRY_SLEEP_SECONDS": "5",

        "WRITE_CSV": "0",
        "BQ_ENABLED": "1",
        "BQ_PROJECT_ID": "microgain-9f959",
        "BQ_DATASET": "bc_t",
        "BQ_TABLE": "payguru_transactions_raw",
    })

    module = download_and_import_script(
        bucket_name=S3_BUCKET,
        s3_key=SCRIPT_S3_KEY,
        module_name=f"payguru_transactions_export_{mode}",
    )
    patch_bigquery_client(module)

    old_argv = sys.argv[:]
    try:
        sys.argv = ["payguru.py", mode]
        module.main()
    finally:
        sys.argv = old_argv


def create_payguru_dag(dag_id, mode, schedule, description):
    with DAG(
        dag_id=dag_id,
        default_args=DEFAULT_ARGS,
        description=description,
        start_date=datetime(2026, 5, 1),
        schedule=schedule,
        catchup=False,
        max_active_runs=1,
        tags=["payguru", "transactions", mode, "bigquery"],
    ) as dag:

        PythonOperator(
            task_id=f"run_payguru_transactions_{mode}",
            python_callable=run_payguru_transactions,
            op_kwargs={"mode": mode},
        )

        return dag


payguru_transactions_daily = create_payguru_dag(
    dag_id="payguru_transactions_daily",
    mode="daily",
    schedule="0 7 * * *",
    description="Payguru T-1 daily transactions load to BigQuery",
)


payguru_transactions_monthly = create_payguru_dag(
    dag_id="payguru_transactions_monthly",
    mode="monthly",
    schedule="0 6 2 * *",
    description="Payguru previous month transactions load to BigQuery",
)


payguru_transactions_manual = create_payguru_dag(
    dag_id="payguru_transactions_manual",
    mode="manual",
    schedule=None,
    description="Payguru month-to-date manual transactions load to BigQuery",
)