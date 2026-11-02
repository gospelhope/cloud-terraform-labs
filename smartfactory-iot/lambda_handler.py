"""Read Kinesis batches, update the latest sensor values, and archive raw data to S3."""
import base64
import json
import os
import hashlib

import boto3
import pg8000.dbapi

_s3 = boto3.client("s3")
_secrets = boto3.client("secretsmanager")


def _db():
    data = _secrets.get_secret_value(SecretId=os.environ["DB_SECRET_ARN"])
    credential = json.loads(data["SecretString"])
    return pg8000.dbapi.connect(
        host=os.environ["DB_HOST"],
        database=os.environ["DB_NAME"],
        user=credential["username"],
        password=credential["password"],
        port=int(credential.get("port", 5432)),
        timeout=5,
        ssl_context=True,
    )


def handler(event, context):
    """Write latest-state metadata to RDS and the raw batch to S3."""
    records = []
    for item in event.get("Records", []):
        raw = base64.b64decode(item["kinesis"]["data"])
        payload = json.loads(raw)
        records.append((item["eventID"], payload))

    if not records:
        return {"count": 0}

    conn = _db()
    try:
        cursor = conn.cursor()
        # Do not retain every raw reading in RDS. Raw history is stored in S3.
        # Keep a small, indexed table for dashboard reads.
        cursor.execute("""
            CREATE TABLE IF NOT EXISTS sensor_latest (
                sensor_id TEXT PRIMARY KEY,
                event_time TIMESTAMPTZ,
                payload JSONB NOT NULL,
                updated_at TIMESTAMPTZ DEFAULT NOW()
            )
        """)
        cursor.execute("CREATE INDEX IF NOT EXISTS sensor_latest_time_idx ON sensor_latest (event_time DESC)")
        for event_id, payload in records:
            cursor.execute("""
                INSERT INTO sensor_latest (sensor_id, event_time, payload)
                VALUES (%s, %s, CAST(%s AS JSONB))
                ON CONFLICT (sensor_id) DO UPDATE SET
                    event_time = EXCLUDED.event_time,
                    payload = EXCLUDED.payload,
                    updated_at = NOW()
                WHERE sensor_latest.event_time IS NULL
                   OR EXCLUDED.event_time >= sensor_latest.event_time
            """, (payload.get("sensor_id", "unknown"),
                  payload.get("timestamp"), json.dumps(payload)))
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()

    # A retry writes the same key, rather than making a duplicate batch.
    batch_id = hashlib.sha256("|".join(event_id for event_id, _ in records).encode()).hexdigest()
    key = f"events/{batch_id[:2]}/batch-{batch_id}.jsonl"
    _s3.put_object(
        Bucket=os.environ["RAW_BUCKET"],
        Key=key,
        Body=("\n".join(json.dumps(v) for _, v in records) + "\n").encode(),
        ServerSideEncryption="AES256",
        ContentType="application/x-ndjson",
    )
    return {"count": len(records), "s3_key": key}
