"""Read the latest sensor values for the operational dashboard."""
import datetime
import json
import os

import boto3
import pg8000.dbapi


def handler(event, context):
    info = boto3.client("secretsmanager").get_secret_value(SecretId=os.environ["DB_SECRET_ARN"])
    credentials = json.loads(info["SecretString"])
    db = pg8000.dbapi.connect(
        host=os.environ["DB_HOST"], database=os.environ["DB_NAME"],
        user=credentials["username"], password=credentials["password"],
        port=int(credentials.get("port", 5432)), timeout=5, ssl_context=True,
    )
    try:
        cursor = db.cursor()
        cursor.execute("""
            SELECT sensor_id, event_time, payload
            FROM sensor_latest
            ORDER BY event_time DESC NULLS LAST
            LIMIT 100
        """)
        results = [{"sensor_id": sensor, "timestamp": ts.isoformat() if ts else None,
                    "reading": json.loads(payload) if isinstance(payload, str) else payload}
                   for sensor, ts, payload in cursor.fetchall()]
    finally:
        db.close()
    return {"statusCode": 200, "headers": {"content-type": "application/json"},
            "body": json.dumps({"readings": results})}
