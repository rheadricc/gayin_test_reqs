from airflow import DAG
from airflow.operators.python import PythonOperator
from airflow.operators.empty import EmptyOperator
from datetime import datetime, timedelta
import importlib.util
import boto3
import tempfile
import os
import sys
import logging

logger = logging.getLogger(__name__)

AWS_BUCKET_NAME = 'gain-data-iys-prod'
AWS_AIRFLOW_BUCKET_NAME = 'gain-data-airflow-bucket'
BUSINESS_LOGIC_KEY = 'python_scripts/Prod_Gain_S3_Migration_IYS_To_Bq_Script.py'
MODULE_NAME = 'iys_logic'
FAIL_BASE_PATH = 'copy_fail_files'


def download_and_import_module(bucket_name, key, module_name=MODULE_NAME):
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


def run_business_logic(**context):
    module = download_and_import_module(AWS_AIRFLOW_BUCKET_NAME, BUSINESS_LOGIC_KEY)
    module.insert_data_to_bq(bucket_name=AWS_BUCKET_NAME, fail_base_path=FAIL_BASE_PATH, **context)


with DAG(
        dag_id='Prod_Gain_S3_Migration_IYS_To_Bq_Dag',
        default_args={
            'owner': 'airflow',
            'depends_on_past': False,
            'start_date': datetime(2025, 3, 11, 15, 0, 0),
            'retries': 1,
            'retry_delay': timedelta(minutes=10),
        },
        schedule_interval='2 * * * *',
        catchup=True,
        max_active_runs=1
) as dag:
    start = EmptyOperator(task_id="start")

    insert_data_task = PythonOperator(
        task_id='insert_data_to_bq_task',
        python_callable=run_business_logic,
        provide_context=True
    )

    start >> insert_data_task
