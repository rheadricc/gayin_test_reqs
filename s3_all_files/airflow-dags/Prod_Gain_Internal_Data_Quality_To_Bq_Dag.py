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
    'owner': 'data-quality',
    'depends_on_past': False,
    'start_date': datetime(2025, 6, 24),
    'retries': 1,
    'retry_delay': timedelta(minutes=5),
}

def download_and_import_dq_module(bucket_name, key, module_name='dq_data_quality_module'):
    s3 = boto3.client('s3')
    temp_dir = tempfile.gettempdir()
    local_file_path = os.path.join(temp_dir, f"{module_name}.py")

    s3.download_file(bucket_name, key, local_file_path)
    logger.info(f"📥 Modül S3'ten indirildi: {local_file_path}")

    spec = importlib.util.spec_from_file_location(module_name, local_file_path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    spec.loader.exec_module(module)
    return module

def run_data_quality_check(**context):
    module = download_and_import_dq_module(
        bucket_name='gain-data-airflow-bucket',
        key='python_scripts/Prod_Gain_Internal_Data_Quality_To_Bq_Script.py'
    )
    module.execute_data_quality_checks_from_context(**context)


def run_user_actions_check(**context):
    module = download_and_import_dq_module(
        bucket_name='gain-data-airflow-bucket',
        key='python_scripts/Prod_Gain_Internal_Data_Quality_To_Bq_Script.py'
    )
    etl_date = context["execution_date"].date()
    module.execute_user_actions_quality_check(etl_date=etl_date, context=context)

run_user_actions_dq_task = PythonOperator(
    task_id='run_user_actions_quality_check',
    python_callable=run_user_actions_check,
    provide_context=True,
)

def run_iys_check(**context):
    module = download_and_import_dq_module(
        bucket_name='gain-data-airflow-bucket',
        key='python_scripts/Prod_Gain_Internal_Data_Quality_To_Bq_Script.py'
    )
    etl_date = context["execution_date"].date()
    module.execute_iys_quality_check(etl_date=etl_date, context=context)

with DAG(
    dag_id='Prod_Gain_Internal_Data_Quality_To_Bq_Dag',
    default_args=default_args,
    description='Run daily data quality checks on user data from BQ and alert to Teams.',
    schedule_interval='55 3 * * *',
    catchup=True,
    max_active_runs=1,
    tags=['Data Quality', 'BQ', 'Teams Alert']
) as dag:


    run_dq_checks_task = PythonOperator(
        task_id='run_elastic_user_quality_check',
        python_callable=run_data_quality_check,
        provide_context=True,
    )

    run_user_actions_dq_task = PythonOperator(
        task_id='run_user_actions_quality_check',
        python_callable=run_user_actions_check,
        provide_context=True,
    )

    run_iys_dq_task = PythonOperator(
        task_id='run_iys_quality_check',
        python_callable=run_iys_check,
        provide_context=True,
    )

    run_dq_checks_task >> run_user_actions_dq_task >> run_iys_dq_task


