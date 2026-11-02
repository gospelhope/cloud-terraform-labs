# =============================================================================
# ITC6670 Module 8 - SmartFactory infrastructure refactor
# Based on the provided M8_Midterm_Bloated_Terraform.tf
# =============================================================================

terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

# =============================================================================
# VARIABLES
# =============================================================================

variable "project_name" {
  description = "Project identifier"
  type        = string
  default     = "iot-datalake"
}

variable "environment" {
  description = "Deployment environment"
  type        = string
  default     = "prod"
}

# =============================================================================
# KINESIS DATA STREAMS
# Current: 1,000 shards for 10,000 IoT sensors sending 100 bytes every 5 seconds
# Actual throughput: 10,000 × 100 bytes ÷ 5 sec = 200 KB/sec = 0.2 MB/sec
# =============================================================================

resource "aws_kinesis_stream" "iot_data" {
  name             = "${var.project_name}-iot-stream"
  # FIX: 2,000 records/s needs 2 shards minimum. Use 8 for headroom.
  shard_count      = 8
  retention_period = 24
  # FIX: Enable Kinesis encryption at rest.
  encryption_type = "KMS"
  kms_key_id      = "alias/aws/kinesis"

  shard_level_metrics = [
    "IncomingBytes",
    "IncomingRecords",
    "OutgoingBytes",
    "OutgoingRecords"
  ]

  tags = {
    Name        = "IoT Sensor Data Stream"
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

# =============================================================================
# RDS DATABASE
# Current: db.r5.24xlarge (96 vCPU, 768 GB RAM) for operational metadata
# Actual peak usage: 4 vCPU, 32 GB RAM observed in CloudWatch
# =============================================================================

resource "aws_db_instance" "operational_db" {
  identifier        = "${var.project_name}-rds"
  engine            = "postgres"
  engine_version    = "14.24" # FIX: Update the PostgreSQL 14 minor version.
  instance_class    = "db.r6i.xlarge" # FIX: 4 vCPU and 32 GiB RAM, based on usage.
  allocated_storage = 500
  storage_type      = "gp3" # FIX: Replace gp2 with gp3.

  db_name                     = "iot_operations"
  username                    = "admin"
  manage_master_user_password = true # FIX: Let RDS manage the password.

  backup_retention_period = 7
  multi_az                = false # Same as the starting design.
  publicly_accessible     = false
  skip_final_snapshot     = false # FIX: Take a final snapshot on deletion.
  final_snapshot_identifier = "${var.project_name}-rds-final-${var.environment}"
  vpc_security_group_ids   = [aws_security_group.rds.id]

  storage_encrypted = true # FIX: encrypt RDS storage at rest

  tags = {
    Name        = "IoT Operational DB"
    Environment = var.environment
  }
}

# =============================================================================
# REDSHIFT CLUSTER
# Current: Always-on 8-node cluster
# Actual usage: 2-hour ETL job each night, idle 22 hours/day
# =============================================================================

resource "aws_redshift_cluster" "analytics" {
  cluster_identifier        = "${var.project_name}-redshift"
  database_name             = "iot_analytics"
  master_username           = "admin"
  manage_master_password    = true # FIX: Manage the Redshift password with Secrets Manager.
  node_type                 = "ra3.xlplus" # FIX: Replace retired DC2 nodes.
  number_of_nodes           = 2 # FIX: Start with two nodes; benchmark the ETL.
  cluster_type              = "multi-node"

  encrypted                 = true # FIX: encrypted warehouse storage
  publicly_accessible       = false
  skip_final_snapshot       = false # FIX: Keep a final snapshot.
  final_snapshot_identifier = "${var.project_name}-redshift-final-${var.environment}"
  automated_snapshot_retention_period = 7

  tags = {
    Name        = "IoT Analytics Cluster"
    Environment = var.environment
  }
}

# =============================================================================
# LAMBDA FUNCTION
# Current: 10M invocations/month at 512 MB memory, 15-minute timeout
# Actual execution: avg 200ms, 128 MB memory used (profiling data)
# =============================================================================

resource "aws_lambda_function" "iot_processor" {
  function_name = "${var.project_name}-processor"
  runtime       = "python3.11"
  handler       = "lambda_handler.handler"
  role          = aws_iam_role.lambda_role.arn
  filename         = "${path.module}/lambda_function.zip" # FIX: Package the handler and pg8000.
  source_code_hash = filebase64sha256("${path.module}/lambda_function.zip")
  # FIX: Reduce the 15-minute timeout based on the 200 ms profile.
  timeout       = 30
  memory_size   = 256 # FIX: Lower memory from 512 MB; leave headroom.

  environment {
    variables = {
      DB_HOST       = aws_db_instance.operational_db.address
      DB_NAME       = aws_db_instance.operational_db.db_name
      DB_SECRET_ARN = aws_db_instance.operational_db.master_user_secret[0].secret_arn # FIX: Pass the secret ARN, not a password.
      RAW_BUCKET    = aws_s3_bucket.raw_data.id
      STREAM_NAME   = aws_kinesis_stream.iot_data.name
    }
  }

  # FIX: Put Lambda in the VPC so it can reach RDS.
  vpc_config {
    subnet_ids         = data.aws_subnets.default.ids
    security_group_ids = [aws_security_group.lambda.id]
  }

  tags = {
    Name        = "IoT Processor Lambda"
    Environment = var.environment
  }
}

resource "aws_iam_role" "lambda_role" {
  name = "${var.project_name}-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "lambda_policy" {
  name = "${var.project_name}-lambda-policy"
  role = aws_iam_role.lambda_role.id

  # FIX: Replace wildcard access with the actions this handler needs.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadKinesisStream"
        Effect   = "Allow"
        Action   = ["kinesis:DescribeStream", "kinesis:DescribeStreamSummary", "kinesis:GetRecords", "kinesis:GetShardIterator", "kinesis:ListShards"]
        Resource = [aws_kinesis_stream.iot_data.arn]
      },
      {
        Sid      = "WriteRawEvents"
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = ["${aws_s3_bucket.raw_data.arn}/events/*", "${aws_s3_bucket.raw_data.arn}/aws/lambda/*"]
      },
      {
        # FIX: Lambda's S3 failure destination also needs ListBucket.
        Sid      = "ListFailureDestinationBucket"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = [aws_s3_bucket.raw_data.arn]
      },
      {
        Sid      = "DecryptKinesis"
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = [data.aws_kms_key.kinesis.arn]
      },
      {
        Sid      = "ReadRdsSecret"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = [aws_db_instance.operational_db.master_user_secret[0].secret_arn]
      }
    ]
  })
}

# FIX: Trigger the Lambda from Kinesis.
resource "aws_lambda_event_source_mapping" "kinesis_to_processor" {
  event_source_arn                   = aws_kinesis_stream.iot_data.arn
  function_name                      = aws_lambda_function.iot_processor.arn
  starting_position                  = "TRIM_HORIZON" # FIX: Read available records when first connected.
  batch_size                         = 100
  maximum_batching_window_in_seconds = 0
  bisect_batch_on_function_error     = true
  maximum_retry_attempts             = 3
  # FIX: Send failed batches to S3 for review and replay.
  destination_config {
    on_failure { destination_arn = aws_s3_bucket.raw_data.arn }
  }
  # Replaying failed batches is an operational step, not automatic.
}

# FIX: Attach the AWS Lambda logging and VPC policies.
resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "lambda_vpc" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

# =============================================================================
# S3 DATA LAKE — ALL THREE LAYERS
# Current: All data stored in S3 Standard, no lifecycle policies
# =============================================================================

resource "aws_s3_bucket" "raw_data" {
  bucket = "${var.project_name}-raw-${var.environment}"
  tags   = { Environment = var.environment, Layer = "Bronze" }
}

resource "aws_s3_bucket" "processed_data" {
  bucket = "${var.project_name}-processed-${var.environment}"
  tags   = { Environment = var.environment, Layer = "Silver" }
}

resource "aws_s3_bucket" "analytics_data" {
  bucket = "${var.project_name}-analytics-${var.environment}"
  tags   = { Environment = var.environment, Layer = "Gold" }
}

# FIX: Set bucket encryption and public access explicitly for all three zones.
resource "aws_s3_bucket_server_side_encryption_configuration" "raw_encryption" {
  bucket = aws_s3_bucket.raw_data.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}
resource "aws_s3_bucket_server_side_encryption_configuration" "processed_encryption" {
  bucket = aws_s3_bucket.processed_data.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}
resource "aws_s3_bucket_server_side_encryption_configuration" "analytics_encryption" {
  bucket = aws_s3_bucket.analytics_data.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "raw" {
  bucket                  = aws_s3_bucket.raw_data.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
resource "aws_s3_bucket_public_access_block" "processed" {
  bucket                  = aws_s3_bucket.processed_data.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
resource "aws_s3_bucket_public_access_block" "analytics" {
  bucket                  = aws_s3_bucket.analytics_data.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# FIX: Keep older object versions in all three buckets.
resource "aws_s3_bucket_versioning" "raw" {
  bucket = aws_s3_bucket.raw_data.id
  versioning_configuration { status = "Enabled" }
}
resource "aws_s3_bucket_versioning" "processed" {
  bucket = aws_s3_bucket.processed_data.id
  versioning_configuration { status = "Enabled" }
}
resource "aws_s3_bucket_versioning" "analytics" {
  bucket = aws_s3_bucket.analytics_data.id
  versioning_configuration { status = "Enabled" }
}

# FIX: The lifecycle prefix matches Lambda's events/ writes.
# Objects must exceed 128 KiB here. Smaller batches need compaction first.
resource "aws_s3_bucket_lifecycle_configuration" "raw" {
  bucket = aws_s3_bucket.raw_data.id
  rule {
    id     = "archive-batched-raw-events"
    status = "Enabled"
    filter {
      and {
        prefix                   = "events/"
        object_size_greater_than = 131072
      }
    }
    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }
    transition {
      days          = 90
      storage_class = "GLACIER_IR"
    }
    noncurrent_version_transition {
      noncurrent_days = 30
      storage_class   = "STANDARD_IA"
    }
    noncurrent_version_transition {
      noncurrent_days = 90
      storage_class   = "GLACIER_IR"
    }
  }
}

# FIX: Put the Glue script in S3 before creating the job.
resource "aws_s3_object" "glue_script" {
  bucket                 = aws_s3_bucket.raw_data.id
  key                    = "scripts/etl.py"
  source                 = "${path.module}/glue_etl.py"
  etag                   = filemd5("${path.module}/glue_etl.py")
  server_side_encryption = "AES256"
  depends_on             = [aws_s3_bucket_public_access_block.raw]
}

# =============================================================================
# GLUE ETL JOB
# Current: g.2X worker (8 vCPU, 32 GB RAM) with 20 workers, no auto-scaling
# =============================================================================

resource "aws_glue_job" "etl_job" {
  name         = "${var.project_name}-etl"
  role_arn     = aws_iam_role.glue_role.arn
  glue_version = "4.0"

  command {
    # FIX: Point Glue at the uploaded script.
    script_location = "s3://${aws_s3_bucket.raw_data.bucket}/${aws_s3_object.glue_script.key}"
    python_version  = "3"
  }

  # FIX: Allow Glue to scale up to ten G.1X workers.
  worker_type       = "G.1X"
  number_of_workers = 10
  timeout           = 60 # FIX: Limit runaway jobs to one hour.

  default_arguments = {
    "--job-language"      = "python"
    "--enable-metrics"    = "true"
    "--enable-auto-scaling" = "true" # FIX: Enable worker autoscaling.
    "--TempDir"           = "s3://${aws_s3_bucket.processed_data.bucket}/tmp/"
    "--source_bucket"     = aws_s3_bucket.raw_data.bucket
    "--target_bucket"     = aws_s3_bucket.processed_data.bucket
    "--analytics_bucket"  = aws_s3_bucket.analytics_data.bucket
  }

  tags = {
    Name        = "IoT ETL Job"
    Environment = var.environment
  }
}

resource "aws_iam_role" "glue_role" {
  name = "${var.project_name}-glue-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "glue.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "glue_service" {
  role       = aws_iam_role.glue_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

resource "aws_iam_role_policy" "glue_s3_access" {
  name = "${var.project_name}-glue-s3"
  role = aws_iam_role.glue_role.id

  # FIX: Read Bronze events, write Silver/Gold, and allow overwrite cleanup
  # only within the ETL output prefixes.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
        Resource = [aws_s3_bucket.raw_data.arn, aws_s3_bucket.processed_data.arn, aws_s3_bucket.analytics_data.arn]
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = ["${aws_s3_bucket.raw_data.arn}/events/*", "${aws_s3_bucket.raw_data.arn}/scripts/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = ["${aws_s3_bucket.processed_data.arn}/silver/*", "${aws_s3_bucket.processed_data.arn}/tmp/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = ["${aws_s3_bucket.analytics_data.arn}/gold/*"]
      }
    ]
  })
}

# =============================================================================
# NETWORK ISOLATION AND PRIVATE ACCESS
# =============================================================================

# FIX: Use separate Lambda and RDS security groups.
# This example uses the default VPC; a production VPC needs private subnet design.
data "aws_kms_key" "kinesis" {
  key_id = "alias/aws/kinesis"
}

data "aws_vpc" "default" { default = true }
data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}
data "aws_route_tables" "default" { vpc_id = data.aws_vpc.default.id }

resource "aws_security_group" "lambda" {
  name_prefix = "${var.project_name}-lambda-"
  vpc_id      = data.aws_vpc.default.id
  description = "Lambda egress to RDS, S3, and Secrets Manager VPC endpoint"
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "rds" {
  name_prefix = "${var.project_name}-rds-"
  vpc_id      = data.aws_vpc.default.id
  description = "PostgreSQL traffic from Lambda only"
  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.lambda.id]
  }
}

resource "aws_security_group" "secrets_endpoint" {
  name_prefix = "${var.project_name}-secrets-vpce-"
  vpc_id      = data.aws_vpc.default.id
  description = "Secrets Manager TLS only from the Lambda security group"
  ingress {
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [aws_security_group.lambda.id]
  }
}

# FIX: Let Lambda reach Secrets Manager without NAT.
resource "aws_vpc_endpoint" "secrets_manager" {
  vpc_id              = data.aws_vpc.default.id
  service_name        = "com.amazonaws.us-east-1.secretsmanager"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  subnet_ids          = data.aws_subnets.default.ids
  security_group_ids  = [aws_security_group.secrets_endpoint.id]
}

# FIX: Add an S3 gateway endpoint for Lambda's Bronze writes.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = data.aws_vpc.default.id
  service_name      = "com.amazonaws.us-east-1.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = data.aws_route_tables.default.ids
}

# =============================================================================
# REDSHIFT SCHEDULING — PAUSE IDLE WAREHOUSE HOURS
# =============================================================================

# FIX: Pause Redshift outside the reporting window.
# 01:00–05:00 UTC is a proposed window, not a confirmed job schedule.
resource "aws_iam_role" "redshift_scheduler" {
  name = "${var.project_name}-redshift-schedule"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = ["scheduler.redshift.amazonaws.com", "redshift.amazonaws.com"] }, Action = "sts:AssumeRole" }]
  })
}
resource "aws_iam_role_policy" "redshift_scheduler" {
  role = aws_iam_role.redshift_scheduler.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["redshift:PauseCluster", "redshift:ResumeCluster"]
      Resource = [aws_redshift_cluster.analytics.arn]
    }]
  })
}
resource "aws_redshift_scheduled_action" "resume" {
  name     = "${var.project_name}-resume-nightly"
  schedule = "cron(0 1 * * ? *)" # FIX: Resume at 01:00 UTC.
  iam_role = aws_iam_role.redshift_scheduler.arn
  target_action {
    resume_cluster {
      cluster_identifier = aws_redshift_cluster.analytics.cluster_identifier
    }
  }
  depends_on = [aws_iam_role_policy.redshift_scheduler]
}
resource "aws_redshift_scheduled_action" "pause" {
  name     = "${var.project_name}-pause-nightly"
  schedule = "cron(0 5 * * ? *)" # FIX: Pause at 05:00 UTC.
  iam_role = aws_iam_role.redshift_scheduler.arn
  target_action {
    pause_cluster {
      cluster_identifier = aws_redshift_cluster.analytics.cluster_identifier
    }
  }
  depends_on = [aws_iam_role_policy.redshift_scheduler]
}

# =============================================================================
# OUTPUTS
# =============================================================================

output "kinesis_stream_arn" {
  value = aws_kinesis_stream.iot_data.arn
}

output "rds_endpoint" {
  value     = aws_db_instance.operational_db.address
  sensitive = true # FIX: Hide the address in normal Terraform output.
}

output "redshift_endpoint" {
  value = aws_redshift_cluster.analytics.endpoint
}

output "lambda_function_name" {
  value = aws_lambda_function.iot_processor.function_name
}