from datetime import datetime

from airflow import DAG
from airflow.operators.bash import BashOperator


SCRIPT_PATH = "/opt/airflow/dags/scripts/payguru.py"
PYTHON_PATH = "python"

DEFAULT_ARGS = {
    "owner": "data-team",
    "depends_on_past": False,
    "retries": 1,
}


def create_payguru_dag(dag_id, mode, schedule, description):
    with DAG(
        dag_id=dag_id,
        default_args=DEFAULT_ARGS,
        description=description,
        start_date=datetime(2026, 5, 1),
        schedule=schedule,
        catchup=False,
        tags=["payguru", "transactions", mode],
    ) as dag:

        BashOperator(
            task_id=f"run_payguru_transactions_{mode}",
            bash_command=f"{PYTHON_PATH} {SCRIPT_PATH} {mode}",
        )

        return dag


payguru_transactions_daily = create_payguru_dag(
    dag_id="payguru_transactions_daily",
    mode="daily",
    schedule="0 7 * * *",
    description="Payguru T-1 daily transactions export",
)


payguru_transactions_monthly = create_payguru_dag(
    dag_id="payguru_transactions_monthly",
    mode="monthly",
    schedule="0 6 2 * *",
    description="Payguru previous month transactions export",
)


payguru_transactions_manual = create_payguru_dag(
    dag_id="payguru_transactions_manual",
    mode="manual",
    schedule=None,
    description="Payguru month-to-date manual transactions export",
)