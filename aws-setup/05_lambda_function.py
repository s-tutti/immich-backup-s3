"""
Daily health check for the Immich backup. Posts directly to a Slack
Incoming Webhook (no SNS in between).

Env vars (set on the Lambda configuration):
    SLACK_WEBHOOK_URL  - Slack incoming webhook URL
    BUCKET             - S3 bucket containing full/* and incremental/*

Threshold logic:
    - Full backup must exist within FULL_MAX_AGE_DAYS (default 200d).
    - Incremental backup must exist within INCREMENTAL_MAX_AGE_DAYS (default 8d).
"""
import datetime
import json
import os
import urllib.request

import boto3

WEBHOOK = os.environ["SLACK_WEBHOOK_URL"]
BUCKET = os.environ["BUCKET"]

FULL_MAX_AGE_DAYS = int(os.environ.get("FULL_MAX_AGE_DAYS", "200"))
INCREMENTAL_MAX_AGE_DAYS = int(os.environ.get("INCREMENTAL_MAX_AGE_DAYS", "8"))

s3 = boto3.client("s3")


def list_all(prefix):
    paginator = s3.get_paginator("list_objects_v2")
    objs = []
    for page in paginator.paginate(Bucket=BUCKET, Prefix=prefix):
        objs.extend(page.get("Contents", []))
    return objs


def latest_lastmod(objs):
    return max((o["LastModified"] for o in objs), default=None)


def group_by_date(objs):
    groups = {}
    for o in objs:
        parts = o["Key"].split("/")
        if len(parts) < 2:
            continue
        groups.setdefault(parts[1], []).append(o)
    return groups


def format_inventory(full_objs, inc_objs):
    lines = []
    for label, objs in (("FULL", full_objs), ("INCREMENTAL", inc_objs)):
        lines.append(f"== {label} ==")
        gs = group_by_date(objs)
        if not gs:
            lines.append("  (none)")
            continue
        for date_key in sorted(gs.keys(), reverse=True):
            g = gs[date_key]
            # Count and total only data chunks; the manifest.json is metadata
            # written by the backup script itself, not a data part.
            parts_only = [o for o in g if not o["Key"].endswith("/manifest.json")]
            total = sum(o["Size"] for o in parts_only)
            latest = max(o["LastModified"] for o in g)
            lines.append(
                f"  {date_key} : {len(parts_only):>3d} parts, "
                f"{total / 1e9:6.1f} GB, {latest:%Y-%m-%d %H:%M UTC}"
            )
    return "\n".join(lines)


def post_slack(text):
    payload = {"text": text}
    req = urllib.request.Request(
        WEBHOOK,
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=10) as resp:
        return resp.status


def lambda_handler(event, context):
    now = datetime.datetime.now(datetime.timezone.utc)

    full_objs = list_all("full/")
    inc_objs = list_all("incremental/")

    full_latest = latest_lastmod(full_objs)
    inc_latest = latest_lastmod(inc_objs)

    full_age = (now - full_latest).days if full_latest else None
    inc_age = (now - inc_latest).days if inc_latest else None

    issues = []
    if full_age is None:
        issues.append("No full backup found in S3.")
    elif full_age > FULL_MAX_AGE_DAYS:
        issues.append(
            f"Latest full backup is {full_age}d old "
            f"(threshold: {FULL_MAX_AGE_DAYS}d)."
        )
    if inc_age is None:
        issues.append("No incremental backup found in S3.")
    elif inc_age > INCREMENTAL_MAX_AGE_DAYS:
        issues.append(
            f"Latest incremental is {inc_age}d old "
            f"(threshold: {INCREMENTAL_MAX_AGE_DAYS}d)."
        )

    inventory = format_inventory(full_objs, inc_objs)

    if issues:
        head = ":rotating_light: *Immich backup health: ALERT*"
        body = "\n".join(f"• {i}" for i in issues)
    else:
        head = ":white_check_mark: *Immich backup health: OK*"
        body = (
            f"latest full = {full_age}d ago, "
            f"latest incremental = {inc_age}d ago"
        )

    msg = f"{head}\n{body}\n```\n{inventory}\n```"
    post_slack(msg)

    return {"status": "alert" if issues else "ok", "issues": issues}
