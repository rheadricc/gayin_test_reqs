from airflow import DAG
from airflow.operators.python import PythonOperator
from airflow.providers.postgres.operators.postgres import PostgresOperator
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
    'start_date': datetime(2025, 5, 27, 10, 0, 0),
    'retries': 1,
    'retry_delay': timedelta(minutes=5),
}

# S3'ten script indirip modül olarak yükle
def download_and_import_module(bucket_name, script_key, module_name='user_actions_logic'):
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

def run_logic_from_s3(bucket_name, script_key, s3_path, execution_date_str, **context):
    module = download_and_import_module(bucket_name, script_key)
    execution_date = datetime.fromisoformat(execution_date_str)

    # 🔥 Sadece bir kez çağır
    module.insert_data(
        bucket_name='gain-data-identity-prod',
        s3_path=s3_path,
        execution_date=execution_date
    )


with DAG(
    'Prod_Gain_S3_User_Actions_To_Redshift_Dag',
    max_active_runs=1,
    default_args=default_args,
    description='Load user-actions from S3 to Redshift via dynamic module import',
    schedule_interval='4 * * * *',
    catchup=True,
) as dag:
    bucket_name = 'gain-data-airflow-bucket'
    script_key = 'python_scripts/Prod_Gain_S3_User_Actions_To_Redshift_Script.py'

    delete_old_data_task = PostgresOperator(
        task_id='delete_old_data_task',
        postgres_conn_id='Redshift_Serverless_Prod_User',
        sql="""
        DELETE FROM int_transaction.user_actions_prod
        WHERE inserted_date >= '{{ (execution_date + macros.timedelta(hours=1)).replace(tzinfo=None).strftime('%Y-%m-%d %H:%M:%S') }}'
        AND inserted_date < '{{ (next_execution_date + macros.timedelta(hours=1)).replace(tzinfo=None).strftime('%Y-%m-%d %H:%M:%S') }}';
        """
    )

    insert_data_task = PythonOperator(
        task_id='insert_data_to_redshift_task',
        python_callable=run_logic_from_s3,
        provide_context=True,
        op_kwargs={
            'bucket_name': bucket_name,
            'script_key': script_key,
            's3_path': "{{ execution_date.strftime('success/%Y/%m/%d/%H/') }}",
            'execution_date_str': "{{ execution_date.strftime('%Y-%m-%dT%H:%M:%S') }}"
        }
    )

    delete_old_data_task >> insert_data_task
