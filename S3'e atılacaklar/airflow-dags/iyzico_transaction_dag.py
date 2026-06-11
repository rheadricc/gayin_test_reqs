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
SCRIPT_S3_KEY = "python_scripts/iyzico_transaction_export.py"

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
    print(f"📥 S3'ten Iyzico script indirildi: {local_file_path}")

    spec = importlib.util.spec_from_file_location(module_name, local_file_path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    spec.loader.exec_module(module)
    return module


def run_iyzico_transactions(mode: str, **kwargs):
    os.environ.update({
        "IYZICO_API_KEY": Variable.get("IYZICO_API_KEY"),
        "IYZICO_SECRET_KEY": Variable.get("IYZICO_SECRET_KEY"),
        "IYZICO_BASE_URL": Variable.get("IYZICO_BASE_URL", default_var="https://api.iyzipay.com"),

        "DEBUG": "0",
        "WRITE_CSV": "0",
        "BQ_ENABLED": "1",
        "BQ_PROJECT_ID": "microgain-9f959",
        "BQ_DATASET": "bc_t",
        "BQ_TABLE": "iyzico_transactions_raw",
        "BQ_INSERT_BATCH_SIZE": "500",
    })

    module = download_and_import_script(
        bucket_name=S3_BUCKET,
        s3_key=SCRIPT_S3_KEY,
        module_name=f"iyzico_transaction_export_{mode}",
    )
    patch_bigquery_client(module)

    old_argv = sys.argv[:]
    try:
        sys.argv = ["iyzico_transaction_export.py", mode]
        module.main()
    finally:
        sys.argv = old_argv


def create_iyzico_dag(dag_id, mode, schedule, description):
    with DAG(
        dag_id=dag_id,
        default_args=DEFAULT_ARGS,
        description=description,
        start_date=datetime(2026, 5, 1),
        schedule=schedule,
        catchup=False,
        max_active_runs=1,
        tags=["iyzico", "transactions", mode, "bigquery"],
    ) as dag:

        PythonOperator(
            task_id=f"run_iyzico_transactions_{mode}",
            python_callable=run_iyzico_transactions,
            op_kwargs={"mode": mode},
        )

        return dag


iyzico_transactions_daily = create_iyzico_dag(
    dag_id="iyzico_transactions_daily",
    mode="daily",
    schedule="0 7 * * *",
    description="Iyzico T-1 daily transactions load to BigQuery",
)


iyzico_transactions_monthly = create_iyzico_dag(
    dag_id="iyzico_transactions_monthly",
    mode="monthly",
    schedule="0 6 2 * *",
    description="Iyzico previous month transactions load to BigQuery",
)


iyzico_transactions_manual = create_iyzico_dag(
    dag_id="iyzico_transactions_manual",
    mode="manual",
    schedule=None,
    description="Iyzico month-to-date manual transactions load to BigQuery",
)