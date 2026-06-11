from airflow import DAG
from airflow.operators.python import PythonOperator
from datetime import datetime, timedelta
from airflow.hooks.base import BaseHook
import importlib.util
import boto3
import os
import tempfile
import logging

logger = logging.getLogger(__name__)

AWS_CONN_ID = 'aws_default'
AWS_BUCKET_NAME = 'gain-data-airflow-bucket'
BUSINESS_LOGIC_KEY = 'python_scripts/Prod_Gain_S3_Migration_Adjust_To_Bq_Script.py'  # S3 içindeki business logic script yolu


def download_and_import_module(bucket_name, key, module_name='adjust_bq_logic'):
    aws_conn = BaseHook.get_connection(AWS_CONN_ID)
    s3 = boto3.client('s3',
                      aws_access_key_id=aws_conn.login,
                      aws_secret_access_key=aws_conn.password,
                      region_name='eu-west-1')

    temp_dir = tempfile.gettempdir()
    local_path = os.path.join(temp_dir, module_name + '.py')
    s3.download_file(bucket_name, key, local_path)
    logger.info(f"✅ S3'ten script indirildi: {local_path}")

    spec = importlib.util.spec_from_file_location(module_name, local_path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def list_files_callable(**kwargs):
    logic = download_and_import_module(AWS_BUCKET_NAME, BUSINESS_LOGIC_KEY)
    logic.list_s3_files(execution_date=kwargs['ds'], context=kwargs, send_slack=logic.send_slack, send_teams=logic.send_teams)

def process_files_callable(**kwargs):
    logic = download_and_import_module(AWS_BUCKET_NAME, BUSINESS_LOGIC_KEY)
    logic.process_files(context=kwargs, send_slack=logic.send_slack, send_teams=logic.send_teams)



with DAG(
    dag_id='Prod_Gain_S3_Migration_Adjust_To_Bq_Dag',
    default_args={
        'owner': 'airflow',
        'retries': 1,
        'retry_delay': timedelta(minutes=5),
    },
    description='S3 to BQ modular DAG with external business logic',
    start_date=datetime(2025, 2, 4),
    schedule_interval='35 3 * * *',
    max_active_runs=1,
    catchup=True
) as dag:

    list_s3_files_task = PythonOperator(
        task_id='list_s3_files',
        python_callable=list_files_callable
    )

    process_files_task = PythonOperator(
        task_id='process_files',
        python_callable=process_files_callable
    )

    list_s3_files_task >> process_files_task
