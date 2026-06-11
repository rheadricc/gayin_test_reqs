from airflow import DAG
from airflow.operators.python import PythonOperator
from airflow.utils.task_group import TaskGroup
from datetime import datetime, timedelta
import boto3
import tempfile
import importlib.util
import os
import sys
import logging

logger = logging.getLogger(__name__)

default_args = {
    'owner': 'airflow',
    'start_date': datetime(2025, 4, 16),
    'retries': 1,
    'retry_delay': timedelta(minutes=5),
}

def download_and_import_module(bucket_name, key, module_name='user_action_validator'):
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

def create_validation_task_group(group_id, s3_bucket, s3_prefix_template, bq_table):
    def _validation_callable(**context):
        execution_date = context['execution_date']
        module = download_and_import_module(
            bucket_name='gain-data-airflow-bucket',
            key='python_scripts/Prod_Gain_S3_Data_Count_Validator_To_Bq_Script.py'
        )
        module.run_validation(
            s3_bucket=s3_bucket,
            s3_prefix_template=s3_prefix_template,
            bq_table=bq_table,
            execution_date=execution_date,
            context=context
        )

    with TaskGroup(group_id=group_id) as tg:
        PythonOperator(
            task_id='validate',
            python_callable=_validation_callable,
            provide_context=True
        )
    return tg

with DAG(
    dag_id='Prod_Gain_S3_Data_Count_Validator_To_Bq_Dag',
    default_args=default_args,
    schedule_interval='5 1 * * *',
    catchup=True,
    max_active_runs=1,
    tags=['validation']
) as dag:

    # örnek validation taskgroup 1
    user_actions_group = create_validation_task_group(
        group_id='user_actions',
        s3_bucket='gain-data-identity-prod',
        s3_prefix_template='success/%Y/%m/%d/',
        bq_table='`microgain-9f959.aws_s3_to_bq_migration.user_actions`'
    )

    # örnek validation taskgroup 2
    iys_group = create_validation_task_group(
        group_id='iys_subscriptions',
        s3_bucket='gain-data-iys-prod',
        s3_prefix_template='success/%Y/%m/%d/',
        bq_table='`microgain-9f959.aws_s3_to_bq_migration.iys_subs`'
    )

    subs_group = create_validation_task_group(
        group_id='subscriptions',
        s3_bucket='gain-data-prod-pay-subs',
        s3_prefix_template='success/%Y/%m/%d/',
        bq_table='`microgain-9f959.aws_s3_to_bq_migration.subs_payment`'
    )

    user_actions_group >> iys_group >> subs_group
