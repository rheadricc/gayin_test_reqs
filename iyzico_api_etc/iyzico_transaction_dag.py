from datetime import datetime

from airflow import DAG
from airflow.operators.bash import BashOperator


SCRIPT_PATH = "/opt/airflow/dags/scripts/iyzico_transactions_export.py"
PYTHON_PATH = "python"

DEFAULT_ARGS = {
    "owner": "data-team",
    "depends_on_past": False,
    "retries": 1,
}


def create_iyzico_dag(dag_id, mode, schedule, description):
    with DAG(
        dag_id=dag_id,
        default_args=DEFAULT_ARGS,
        description=description,
        start_date=datetime(2026, 5, 1),
        schedule=schedule,
        catchup=False,
        tags=["iyzico", "transactions", mode],
    ) as dag:

        BashOperator(
            task_id=f"run_iyzico_transactions_{mode}",
            bash_command=f"{PYTHON_PATH} {SCRIPT_PATH} {mode}",
        )

        return dag


iyzico_transactions_daily = create_iyzico_dag(
    dag_id="iyzico_transactions_daily",
    mode="daily",
    schedule="0 7 * * *",
    description="Iyzico T-1 daily transactions export",
)


iyzico_transactions_monthly = create_iyzico_dag(
    dag_id="iyzico_transactions_monthly",
    mode="monthly",
    schedule="0 6 2 * *",
    description="Iyzico previous month transactions export",
)


iyzico_transactions_manual = create_iyzico_dag(
    dag_id="iyzico_transactions_manual",
    mode="manual",
    schedule=None,
    description="Iyzico month-to-date manual transactions export",
)