from airflow import DAG
from airflow.operators.python import PythonOperator
from datetime import datetime, timedelta
import boto3
import tempfile
import os
import sys
import logging
import importlib.util

logger = logging.getLogger(__name__)

default_args = {
    'owner': 'airflow',
    'depends_on_past': False,
    'start_date': datetime(2025, 5, 28, 9, 0, 0),
    'retries': 1,
    'retry_delay': timedelta(minutes=5),
}

def download_and_import_module(bucket_name, script_key, module_name='iys_logic'):
    s3 = boto3.client('s3')
    temp_dir = tempfile.gettempdir()
    local_file_path = os.path.join(temp_dir, f"{module_name}.py")
    s3.download_file(bucket_name, script_key, local_file_path)
    logger.info(f"📥 S3'ten script indirildi: {local_file_path}")

    spec = importlib.util.spec_from_file_location(module_name, local_file_path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    spec.loader.exec_module(module)
    return module

# Fonksiyonları ayrı ayrı çalıştırmak için PythonOperator'larda kullanılacak çağrıcılar
def delete_old_data_runner(**context):
    module = download_and_import_module('gain-data-airflow-bucket', 'python_scripts/Prod_Gain_S3_IYS_To_Redshift_Script.py')
    execution_date = context['execution_date']
    module.delete_old_data(execution_date)

def insert_data_runner(**context):
    module = download_and_import_module('gain-data-airflow-bucket', 'python_scripts/Prod_Gain_S3_IYS_To_Redshift_Script.py')
    execution_date = context['execution_date']
    s3_path = execution_date.strftime('success/%Y/%m/%d/%H/')
    context['execution_date'] = execution_date
    module.insert_data(bucket_name='gain-data-iys-prod', s3_path=s3_path, **context)

def update_inserted_date_runner(**context):
    module = download_and_import_module('gain-data-airflow-bucket', 'python_scripts/Prod_Gain_S3_IYS_To_Redshift_Script.py')
    execution_date = context['execution_date']
    module.update_inserted_date(execution_date)

# DAG tanımı
with DAG(
    'Prod_Gain_S3_IYS_To_Redshift_Dag',
    default_args=default_args,
    description='Load IYS data from S3 to Redshift (step-by-step)',
    schedule_interval='2 * * * *',
    catchup=True,
    max_active_runs=1
) as dag:

    delete_old_data_task = PythonOperator(
        task_id='delete_old_data_task',
        python_callable=delete_old_data_runner,
        provide_context=True
    )

    insert_data_task = PythonOperator(
        task_id='insert_data_task',
        python_callable=insert_data_runner,
        provide_context=True
    )

    update_inserted_date_task = PythonOperator(
        task_id='update_inserted_date_task',
        python_callable=update_inserted_date_runner,
        provide_context=True
    )

    delete_old_data_task >> insert_data_task >> update_inserted_date_task
