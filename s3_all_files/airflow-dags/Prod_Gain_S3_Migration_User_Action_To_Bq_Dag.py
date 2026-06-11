from airflow import DAG
from airflow.operators.python import PythonOperator
from airflow.providers.google.cloud.operators.bigquery import BigQueryInsertJobOperator
from datetime import datetime, timedelta
import boto3
import tempfile
import importlib.util
import os
import sys
import logging

default_args = {
    'owner': 'airflow',
    'depends_on_past': False,
    'start_date': datetime(2025, 3, 6, 14, 0, 0),
    'retries': 1,
    'retry_delay': timedelta(minutes=5),
}

logger = logging.getLogger(__name__)

def download_and_import_module(bucket_name, key, module_name='dynamic_user_action'):
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
        key='python_scripts/Prod_Gain_S3_Migration_User_Action_To_Bq_Script.py'
    )

    module.insert_data_to_bigquery(
        bucket_name='gain-data-identity-prod',
        s3_path=context['execution_date'].strftime('success/%Y/%m/%d/%H/'),
        context=context
    )

with DAG(
    'Prod_Gain_S3_Migration_User_Action_To_Bq_Dag',
    default_args=default_args,
    description='Run business logic from S3 and clean old data before insert',
    schedule_interval='4 * * * *',
    catchup=False,
    max_active_runs=1,
) as dag:


    insert_data_task = PythonOperator(
        task_id='insert_data_to_bigquery_task',
        python_callable=run_business_logic,
        provide_context=True,
    )

    insert_data_task
