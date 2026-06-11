
from airflow.operators.python import PythonOperator
from datetime import datetime, timedelta
from airflow import DAG
import logging
import boto3
import tempfile
import importlib.util
import sys
import os

logger = logging.getLogger(__name__)

default_args = {
    'owner': 'airflow',
    'depends_on_past': False,
    'start_date': datetime(2025, 8, 21),
    'retries': 2,
    'retry_delay': timedelta(minutes=5),
}

def download_and_import_module(bucket_name, key, module_name='dynamic_hourly_GA4_events_count_check'):
    s3 = boto3.client('s3')
    temp_dir = tempfile.gettempdir()
    local_file_path = os.path.join(temp_dir, f"{module_name}.py")

    s3.download_file(bucket_name, key, local_file_path)
    logger.info(f"📥 S3'ten modül indirildi: {local_file_path}")

    spec = importlib.util.spec_from_file_location(module_name, local_file_path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module 
    spec.loader.exec_module(module)
    return module

def run_ga4_hourly_check(**context):
    module = download_and_import_module(
        bucket_name='gain-data-airflow-bucket',
        key='python_scripts/Prod_Gain_GA4_Events_Count_Check_To_Bq.py'
    )
    module.run_ga4_hourly_check(**context)

with DAG(
    'Prod_Gain_GA4_Events_Count_Check_To_Bq_Dag',
    default_args=default_args,
    description='Checking the event counts anomalies as hourly for GA4.',
    schedule_interval="15 * * * *",
    catchup=False,
    tags=['GA4', 'Events', 'Count', 'Check'],
    max_active_runs=1
) as dag:

    run_script_task = PythonOperator(
        task_id='run_ga4_hourly_check',
        python_callable=run_ga4_hourly_check,
        provide_context=True
    )
