import logging
import boto3
import os
import tempfile
import importlib.util
import sys
from datetime import datetime, timedelta
from airflow.operators.python import PythonOperator
from datetime import datetime
from airflow import DAG


logger = logging.getLogger(__name__)


default_args = {
    'owner': 'airflow',
    'depends_on_past': False,
    'start_date': datetime(2025, 4, 14, 3),
    'retries': 1,
    'retry_delay': timedelta(minutes=30),
}

def download_and_import_module(bucket_name, key, module_name='dynamic_test_subs_payment_data'):
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
        key='python_scripts/Test_Gain_Subs_Payment_Data_To_Bq_Script.py'
    )
    module.check_and_load_data_to_bq(bucket_name='gain-data-pay-subs', fail_base_path='copy_fail_files', **context)

with DAG(
    dag_id="Test_Gain_Subs_Payment_Data_To_Bq__Dag",
    default_args=default_args,
    description='Transfer subs_payment data from s3 to Big Query test table',
    schedule_interval='12 * * * *',
    catchup=False,
    tags=["Gain", "Subs", "Payment, Test"],
) as dag:
    
    test_insert_subs_payment_data_to_bq = PythonOperator(
        task_id="Test_Gain_Subs_Payment_Data_To_Bq__Dag",
        python_callable=run_business_logic,  
        provide_context=True
    )

    test_insert_subs_payment_data_to_bq
