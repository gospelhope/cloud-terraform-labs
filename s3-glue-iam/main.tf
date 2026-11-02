# S3 access example adapted from my Module 6 IAM review.
# This policy attaches to an existing Glue IAM role. It does not create any S3 buckets.

terraform {
  required_version = ">= 1.3"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

variable "aws_region" {
  description = "AWS Region for this example."
  type        = string
  default     = "us-east-1"
}

variable "glue_role_name" {
  description = "Name of an existing IAM role used by the Glue job."
  type        = string
}

variable "bronze_bucket_name" {
  description = "Name of the existing source bucket."
  type        = string
}

variable "silver_bucket_name" {
  description = "Name of the existing output bucket."
  type        = string
}

variable "glue_needs_silver_delete" {
  description = "Enable only if the Glue output workflow deletes/replaces existing Silver objects."
  type        = bool
  default     = false
}

resource "aws_iam_role_policy" "glue_s3_access" {
  name = "glue-s3-restricted-access"
  role = var.glue_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ListDataLakeBuckets"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = [
          "arn:aws:s3:::${var.bronze_bucket_name}",
          "arn:aws:s3:::${var.silver_bucket_name}"
        ]
      },
      {
        Sid      = "ReadBronzeObjects"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = ["arn:aws:s3:::${var.bronze_bucket_name}/*"]
      },
      {
        Sid    = "WriteSilverObjects"
        Effect = "Allow"
        Action = concat(
          ["s3:PutObject"],
          var.glue_needs_silver_delete ? ["s3:DeleteObject"] : []
        )
        Resource = ["arn:aws:s3:::${var.silver_bucket_name}/*"]
      }
    ]
  })
}
