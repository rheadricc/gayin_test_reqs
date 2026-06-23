import logging

from airflow.providers.slack.hooks.slack_webhook import SlackWebhookHook


LOGGER = logging.getLogger(__name__)
SLACK_CONN_ID = "slack_default"


def _duration_text(task_instance):
    duration = task_instance.duration
    return f"{duration:.1f}s" if duration is not None else "n/a"


def _result_lines(task_instance):
    result = task_instance.xcom_pull(
        task_ids=task_instance.task_id,
        key="return_value",
    )
    if not isinstance(result, dict):
        return ""

    labels = (
        ("target_date", "Target date"),
        ("row_count", "Loaded rows"),
        ("table_id", "BigQuery table"),
    )
    lines = []
    for key, label in labels:
        value = result.get(key)
        if value is not None:
            formatted = f"`{value}`" if key == "table_id" else value
            lines.append(f"*{label}:* {formatted}")
    return "\n".join(lines)


def _send(text):
    try:
        SlackWebhookHook(slack_webhook_conn_id=SLACK_CONN_ID).send(text=text)
    except Exception:
        LOGGER.exception("Slack notification could not be sent.")


def notify_success(context):
    task_instance = context["task_instance"]
    dag_run = context.get("dag_run")
    run_id = dag_run.run_id if dag_run else context.get("run_id", "n/a")
    result_lines = _result_lines(task_instance)
    result_block = f"\n{result_lines}" if result_lines else ""

    _send(
        ":white_check_mark: *Airflow task succeeded*\n"
        f"*DAG:* `{task_instance.dag_id}`\n"
        f"*Task:* `{task_instance.task_id}`\n"
        f"*Run:* `{run_id}`"
        f"{result_block}\n"
        f"*Duration:* {_duration_text(task_instance)}\n"
        f"<{task_instance.log_url}|Open Airflow log>"
    )


def notify_failure(context):
    task_instance = context["task_instance"]
    dag_run = context.get("dag_run")
    run_id = dag_run.run_id if dag_run else context.get("run_id", "n/a")
    exception = context.get("exception")
    exception_text = str(exception)[:1000] if exception else "Unknown error"

    _send(
        "<!channel>\n"
        ":red_circle: *Airflow task failed*\n"
        f"*DAG:* `{task_instance.dag_id}`\n"
        f"*Task:* `{task_instance.task_id}`\n"
        f"*Run:* `{run_id}`\n"
        f"*Final try:* {task_instance.try_number}\n"
        f"*Error:* `{exception_text}`\n"
        f"<{task_instance.log_url}|Open Airflow log>"
    )
