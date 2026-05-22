from datetime import datetime, timedelta

from airflow import DAG
from airflow.operators.bash import BashOperator


DAG_ID = "gain_kids_profile_full_scan"

PROJECT_DIR = "/opt/airflow/dags/gain_jobs/kids_counter"
PYTHON_BIN = "/opt/airflow/venv/bin/python"
SCRIPT_PATH = f"{PROJECT_DIR}/kids_async_identifier.py"

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

    run_kids_profile_scan = BashOperator(
        task_id="run_kids_profile_scan",
        bash_command=f"""
        cd {PROJECT_DIR}
        {PYTHON_BIN} {SCRIPT_PATH}
        """,
        env={
            "PROD_BASE_URL": "https://api.gain.tv/2da7kf8jf",
            "AUTH_TOKEN": "{{ var.value.GAIN_BO_AUTH_TOKEN }}",

            "PAGE_SIZE": "100",
            "MAX_PAGES": "0",
            "MAX_WORKERS": "35",
            "ENABLE_TQDM": "0",

            "PAUSE_EVERY_PAGES": "50",
            "PAUSE_SECONDS": "10",

            "SCAN_MODE": "full",
            "DATE_FIELD": "updatedAt",
            "LOOKBACK_DAYS": "2",

            "GOOGLE_APPLICATION_CREDENTIALS": "{{ var.value.GOOGLE_APPLICATION_CREDENTIALS_PATH }}",
        },
    )