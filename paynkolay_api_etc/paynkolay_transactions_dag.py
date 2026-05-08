from datetime import datetime

from airflow import DAG
from airflow.operators.bash import BashOperator


SCRIPT_PATH = "/opt/airflow/dags/scripts/paynkolay.py"
PYTHON_PATH = "python"

DEFAULT_ARGS = {
    "owner": "data-team",
    "depends_on_past": False,
    "retries": 1,
}


def create_nkolay_dag(dag_id, mode, schedule, description):
    with DAG(
        dag_id=dag_id,
        default_args=DEFAULT_ARGS,
        description=description,
        start_date=datetime(2026, 5, 1),
        schedule=schedule,
        catchup=False,
        tags=["nkolay", "paynkolay", "transactions", mode],
    ) as dag:

        BashOperator(
            task_id=f"run_nkolay_transactions_{mode}",
            bash_command=f"{PYTHON_PATH} {SCRIPT_PATH} {mode}",
        )

        return dag


nkolay_transactions_daily = create_nkolay_dag(
    dag_id="nkolay_transactions_daily",
    mode="daily",
    schedule="0 7 * * *",
    description="N Kolay / Paynkolay T-1 daily transactions export",
)


nkolay_transactions_monthly = create_nkolay_dag(
    dag_id="nkolay_transactions_monthly",
    mode="monthly",
    schedule="0 6 2 * *",
    description="N Kolay / Paynkolay previous month transactions export",
)


nkolay_transactions_manual = create_nkolay_dag(
    dag_id="nkolay_transactions_manual",
    mode="manual",
    schedule=None,
    description="N Kolay / Paynkolay month-to-date manual transactions export",
)