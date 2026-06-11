from airflow import DAG
from google.cloud import bigquery
from airflow.providers.google.cloud.hooks.bigquery import BigQueryHook
from airflow.providers.postgres.hooks.postgres import PostgresHook
from airflow.operators.python import PythonOperator
from datetime import datetime, timedelta
import boto3
import pandas as pd


default_args = {
    'owner': 'airflow',
    'depends_on_past': False,
    'start_date': datetime(2025, 1, 29, 13),
    'retries': 2,
    'retry_delay': timedelta(minutes=5),
}

def hourly_user_status_data_execute(**kwargs):

    hook = BigQueryHook(gcp_conn_id="google_cloud_default")
    credentials = hook.get_credentials()
    project_id = hook.project_id

    # BigQuery connection
    bq_client = bigquery.Client(credentials=credentials, project=project_id)
    
    # Redshift connection
    redshift_hook = PostgresHook(postgres_conn_id='redshift_default_prod')

    # S3 connection and get sql script
    s3 = boto3.client('s3')
    bucket_name = 'gain-data-airflow-bucket'
    user_status = 'sql_scripts/hourly_user_status_aws.sql'
    user_status_script = s3.get_object(Bucket=bucket_name, Key=user_status)['Body'].read().decode('utf-8')
    
    # Start sql query and get result to the DataFrame
    df = redshift_hook.get_pandas_df(user_status_script)
    print("SQL sonucu DataFrame'e aktarıldı:")
    #print(df)

    # Target BigQuery table
    daily_metrics_aws_table = 'looker_report.hourly_user_status'

    # Load dataframe to the big query
    job_config = bigquery.LoadJobConfig(write_disposition="WRITE_TRUNCATE")
    job = bq_client.load_table_from_dataframe(df, daily_metrics_aws_table, job_config=job_config)
    job.result()
    print(f"Sonuçlar başarıyla '{daily_metrics_aws_table}' tablosuna insert edildi.")

with DAG(
    'hourly-prod-user-status-data',
    default_args=default_args,
    description='Transfer prod_subs_pay data from Redshift to Big Query for total paid user daily metric report table',
    schedule_interval='*/30 * * * *',  # Her yarım saatte bir
    catchup=False,
) as dag:

    run_sql = PythonOperator(
        task_id='hourly_user_status_data_execute',
        python_callable=hourly_user_status_data_execute,
        provide_context=True,  # Obtain like execution_date variables
    )