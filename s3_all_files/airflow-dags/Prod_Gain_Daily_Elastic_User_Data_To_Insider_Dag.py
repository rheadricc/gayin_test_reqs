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
    'start_date': datetime(2025, 6, 12),
    'retries': 1,
    'retry_delay': timedelta(minutes=5),
}

def download_and_import_module(bucket_name, key, module_name='dynamic_daily_user_data_to_upsert_api'):
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
    module = download_and_import_module(
        bucket_name='gain-data-airflow-bucket',
        key='python_scripts/Prod_Gain_Daily_Elastic_User_Data_To_Insider_Script.py'
    )
    module.delete_existing_data(**context)
    module.execute_daily_custom_user_attributes_sql(**context)
    module.send_users_to_insider(**context)

with DAG(
    'Prod_Gain_Daily_Elastic_User_Data_To_Insider_Dag',
    default_args=default_args,
    description='Send elastic user data from BQ to Insider prod environment using upsert_api.',
    schedule_interval="45 3 * * *",
    catchup=True,
    tags=['UPSERT API', 'INSIDER', 'Daily', 'Elastic User'],
    max_active_runs=1
) as dag:

    run_script_task = PythonOperator(
        task_id='run_business_logic',
        python_callable=run_business_logic,
        provide_context=True
    )
