from airflow.operators.python import PythonOperator
from datetime import datetime, timedelta
from airflow import DAG
import importlib.util
import pandas as pd
import boto3
import tempfile
import sys
import os

def download_and_import_function(bucket_name, s3_key, module_name='dynamic_neverwatched_user_scd_script'):
    s3 = boto3.client('s3')
    temp_dir = tempfile.gettempdir()
    local_file_path = os.path.join(temp_dir, f"{module_name}.py")
    s3.download_file(bucket_name, s3_key, local_file_path)
    print(f"📥 S3'ten modül indirildi: {local_file_path}")
    spec = importlib.util.spec_from_file_location(module_name, local_file_path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    spec.loader.exec_module(module)
    return module

default_args = {
    "owner": "airflow",
    "depends_on_past": False,
    "start_date": datetime(2025, 4, 24),
    "retries": 1,
    "retry_delay": timedelta(minutes=5),
}

with DAG(
    dag_id="Prod_Gain_Never_Watched_Users_To_Bq_Scd_Dag",
    default_args=default_args,
    schedule_interval="45 20 * * 0",
    catchup=False,
    max_active_runs=1,
    tags=["segmented", "never_watched","user", "scd"],
) as dag:

    def run_fetched_script(**kwargs):
        execution_date = kwargs["execution_date"]
        if isinstance(execution_date, str):
            execution_date = pd.to_datetime(execution_date)

        module = download_and_import_function(
            bucket_name="gain-data-airflow-bucket",
            s3_key="python_scripts/Prod_Gain_Never_Watched_Users_To_Bq_Scd.py"
        )
        module.run_sql_ordered(execution_date=execution_date)

    execute_ordered_sqls_for_never_watched_users = PythonOperator(
        task_id="run_sql_ordered_for_never_watched_segmented_users",
        python_callable=run_fetched_script,
        provide_context=True,
    )

    execute_ordered_sqls_for_never_watched_users
