from datetime import datetime

from airflow import DAG
from airflow.operators.bash import BashOperator


SCRIPT_PATH = "/opt/airflow/dags/scripts/google_sales_export.py"
PYTHON_PATH = "python"


DEFAULT_ARGS = {
    "owner": "data-team",
    "depends_on_past": False,
    "retries": 1,
}


def create_google_play_sales_dag(
    dag_id: str,
    mode: str,
    schedule,
    description: str,
):
    with DAG(
        dag_id=dag_id,
        default_args=DEFAULT_ARGS,
        description=description,
        start_date=datetime(2026, 4, 1),
        schedule=schedule,
        catchup=False,
        tags=["google_play", "sales", mode],
    ) as dag:

        run_export = BashOperator(
            task_id=f"run_google_play_sales_{mode}",
            bash_command=f"{PYTHON_PATH} {SCRIPT_PATH} {mode}",
        )

        return dag


google_play_sales_daily = create_google_play_sales_dag(
    dag_id="google_play_sales_daily",
    mode="daily",
    schedule="0 7 * * *",
    description="Google Play estimated sales T-1 daily export",
)


google_play_sales_monthly = create_google_play_sales_dag(
    dag_id="google_play_sales_monthly",
    mode="monthly",
    schedule="0 6 2 * *",
    description="Google Play previous month sales export on every 2nd day at 06:00",
)


google_play_sales_manual = create_google_play_sales_dag(
    dag_id="google_play_sales_manual",
    mode="manual",
    schedule=None,
    description="Manual Google Play month-to-date sales export from month start to T-1",
)