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
    'retry_delay': timedelta(minutes=5),
}

def download_and_import_module(bucket_name, key, module_name='dynamic_bo_promotion_data'):
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
        key='python_scripts/Prod_Gain_BO_Promotion_Data_To_Bq_Script.py'
    )
    module.get_all_detailed_promotion_data_and_insert_bq(context=context)

with DAG(
    dag_id="Prod_Gain_BO_Promotion_Data_To_Bq_Dag",
    default_args=default_args,
    description='Transfer promotion data from back office to Big Query table',
    schedule_interval='50 0 * * *',  # Her gün gece 03:50 utc +3
    catchup=False,
    tags=["Gain", "Promotion", "BO"],
) as dag:
    
    sync_titles = PythonOperator(
        task_id="Prod_Gain_BO_Promotion_Data_To_Bq_Dag",
        python_callable=run_business_logic,
        provide_context=True
    )
