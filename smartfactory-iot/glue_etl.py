"""Read new sensor files from Bronze and write Parquet to Silver and Gold."""
import sys
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from pyspark.sql import functions as F
from awsglue.context import GlueContext
from awsglue.job import Job

args = getResolvedOptions(sys.argv, ["JOB_NAME", "source_bucket", "target_bucket", "analytics_bucket"])
glue_context = GlueContext(SparkContext.getOrCreate())
spark = glue_context.spark_session
job = Job(glue_context)
job.init(args["JOB_NAME"], args)

# The bookmark tracks processed objects; it must be tested with real input.
source = f"s3://{args['source_bucket']}/events/"
new_files = glue_context.create_dynamic_frame.from_options(
    connection_type="s3",
    connection_options={"paths": [source], "recurse": True},
    format="json",
    transformation_ctx="bronze_events",
)
if new_files.count() > 0:
    raw = new_files.toDF()
    silver = raw.withColumn("event_timestamp", F.to_timestamp("timestamp")) \
                .withColumn("event_date", F.to_date("event_timestamp"))
    silver.write.mode("append").partitionBy("event_date").parquet(
        f"s3://{args['target_bucket']}/silver/"
    )
    gold = (silver.groupBy("sensor_id", F.window("event_timestamp", "1 minute"))
            .agg(F.count("*").alias("reading_count"),
                 F.avg("temperature").alias("average_temperature")))
    gold.write.mode("append").parquet(f"s3://{args['analytics_bucket']}/gold/")
job.commit()
