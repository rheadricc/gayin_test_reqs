from airflow import DAG
from google.cloud import bigquery
from airflow.providers.google.cloud.hooks.bigquery import BigQueryHook
from airflow.providers.postgres.hooks.postgres import PostgresHook
from airflow.operators.python import PythonOperator
from datetime import datetime, timedelta, timezone
import pytz
import boto3
import pandas as pd


default_args = {
    'owner': 'airflow',
    'depends_on_past': False,
    'start_date': datetime(2025, 1, 23, 13),
    'retries': 2,
    'retry_delay': timedelta(minutes=3),
}

# Target BigQuery table
daily_metrics_aws_table = 'looker_report.Daily_Report_Metrics_AWS_copy'

# S3 connection and get sql script
def get_sql_script_from_s3(key):
    s3 = boto3.client('s3')
    bucket_name = 'gain-data-airflow-bucket'
    return s3.get_object(Bucket=bucket_name, Key=key)['Body'].read().decode('utf-8')

def get_bq_client():
    hook = BigQueryHook(gcp_conn_id="google_cloud_default")
    credentials = hook.get_credentials()
    project_id = hook.project_id
    return bigquery.Client(credentials=credentials, project=project_id)

def execute_daily_metrics_sql(**kwargs):

    now_istanbul = datetime.now(pytz.timezone("Europe/Istanbul"))
    execution_date_str = now_istanbul.strftime('%Y-%m-%d')

    daily_metrics_script = get_sql_script_from_s3('sql_scripts/daily_metrics_current_date.sql')

    bq_client = get_bq_client()

    # Redshift connection
    redshift_hook = PostgresHook(postgres_conn_id='redshift_default_prod')

    # Start sql query and get result to the DataFrame
    df = redshift_hook.get_pandas_df(daily_metrics_script)
    print("daily_metrics.sql sonucu DataFrame'e aktarıldı:")
    #print(df)

    # Delete query according the Execution for aws_table
    delete_query = f"""
    DELETE FROM `{daily_metrics_aws_table}`
    WHERE date = '{execution_date_str}'
    """
    delete_job = bq_client.query(delete_query)
    delete_job.result()
    print(f"{execution_date_str} tarihli veriler silindi: {daily_metrics_aws_table}")

    # Load dataframe to the big query
    job_config = bigquery.LoadJobConfig(write_disposition="WRITE_APPEND")
    job = bq_client.load_table_from_dataframe(df, daily_metrics_aws_table, job_config=job_config)
    job.result()
    print(f"Sonuçlar başarıyla '{daily_metrics_aws_table}' tablosuna insert edildi.")

with DAG(
    'Prod-Daily-Metrics-Redshift-To-Bq-Current-Date-Dag',
    default_args=default_args,
    description='Transfer prod_subs_pay data from Redshift to Big Query report table for current date.',
    schedule_interval='0 19 * * *',  # UTC 19:00 = Türkiye 22:00
    catchup=False,
) as dag:

    run_sql = PythonOperator(
        task_id='execute_daily_metrics_current_date_sql',
        python_callable=execute_daily_metrics_sql,
        provide_context=True,  # Obtain like execution_date variables
    )
