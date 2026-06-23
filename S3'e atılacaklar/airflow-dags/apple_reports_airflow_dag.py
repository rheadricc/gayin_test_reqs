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
from slack_callbacks import notify_failure, notify_success


S3_BUCKET = "gain-data-airflow-bucket"
SCRIPT_S3_KEY = "python_scripts/apple_monthly_reports.py"

DEFAULT_ARGS = {
    "owner": "data-team",
    "depends_on_past": False,
    "retries": 3,
    "retry_delay": timedelta(hours=1),
}


def download_and_import_script(bucket_name, s3_key, module_name):
    local_path = os.path.join(tempfile.gettempdir(), f"{module_name}.py")
    boto3.client("s3").download_file(bucket_name, s3_key, local_path)

    spec = importlib.util.spec_from_file_location(module_name, local_path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    spec.loader.exec_module(module)
    return module


def patch_bigquery_client(module, gcp_conn_id="google_cloud_default"):
    hook = BigQueryHook(gcp_conn_id=gcp_conn_id)
    credentials = hook.get_credentials()
    project_id = hook.project_id or "microgain-9f959"
    original_client = bigquery.Client

    def airflow_bigquery_client(*args, **kwargs):
        project = kwargs.get("project") or project_id
        return original_client(credentials=credentials, project=project)

    module.bigquery.Client = airflow_bigquery_client


def run_apple_subscriber_daily(**kwargs):
    os.environ.update(
        {
            "RUNNING_IN_AIRFLOW": "1",
            "WRITE_CSV": "0",
            "BQ_ENABLED": "1",
            "APPLE_CONNECT_ISSUER_ID": Variable.get(
                "APPLE_CONNECT_ISSUER_ID"
            ),
            "APPLE_CONNECT_KEY_ID": Variable.get("APPLE_CONNECT_KEY_ID"),
            "APPLE_CONNECT_PRIVATE_KEY": Variable.get(
                "APPLE_CONNECT_PRIVATE_KEY"
            ),
            "APPLE_VENDOR_NUMBER": Variable.get("APPLE_VENDOR_NUMBER"),
            "BQ_PROJECT_ID": Variable.get(
                "FINANCE_BQ_PROJECT_ID",
                default_var="microgain-9f959",
            ),
            "BQ_DATASET": Variable.get(
                "FINANCE_BQ_DATASET",
                default_var="bc_t",
            ),
            "BQ_TABLE": Variable.get(
                "APPLE_SUBSCRIBER_BQ_TABLE",
                default_var="apple_transactions_raw",
            ),
        }
    )

    module = download_and_import_script(
        S3_BUCKET,
        SCRIPT_S3_KEY,
        "apple_monthly_reports_daily",
    )
    patch_bigquery_client(module)

    old_argv = sys.argv[:]
    try:
        sys.argv = ["apple_monthly_reports.py", "daily"]
        return module.export_daily()
    finally:
        sys.argv = old_argv


with DAG(
    dag_id="apple_subscriber_report_daily",
    default_args=DEFAULT_ARGS,
    description="Apple T-1 günlük subscriber report BigQuery yüklemesi",
    start_date=datetime(2026, 6, 1),
    schedule="30 19 * * *",
    catchup=False,
    max_active_runs=1,
    is_paused_upon_creation=True,
    tags=["apple", "finance", "daily", "bigquery"],
) as apple_subscriber_report_daily:
    run_export = PythonOperator(
        task_id="run_apple_subscriber_report_daily",
        python_callable=run_apple_subscriber_daily,
        on_success_callback=notify_success,
        on_failure_callback=notify_failure,
    )
