from datetime import datetime
from airflow import DAG
from airflow.operators.bash import BashOperator

SCRIPT_PATH = "/opt/airflow/dags/scripts/param_transactions_export.py"
PYTHON_PATH = "python"

DEFAULT_ARGS = {
    "owner": "data-team",
    "depends_on_past": False,
    "retries": 1,
}

def create_param_dag(dag_id, mode, schedule, description):
    with DAG(
        dag_id=dag_id,
        default_args=DEFAULT_ARGS,
        description=description,
        start_date=datetime(2026, 5, 1),
        schedule=schedule,
        catchup=False,
        tags=["param", "transactions", mode],
    ) as dag:

        BashOperator(
            task_id=f"run_param_transactions_{mode}",
            bash_command=f"{PYTHON_PATH} {SCRIPT_PATH} {mode}",
        )

        return dag

param_transactions_daily = create_param_dag(
    dag_id="param_transactions_daily",
    mode="daily",
    schedule="0 7 * * *",
    description="Param T-1 daily transactions export",
)

param_transactions_monthly = create_param_dag(
    dag_id="param_transactions_monthly",
    mode="monthly",
    schedule="0 6 2 * *",
    description="Param previous month transactions export",
)

param_transactions_manual = create_param_dag(
    dag_id="param_transactions_manual",
    mode="manual",
    schedule=None,
    description="Param month-to-date manual transactions export",
)