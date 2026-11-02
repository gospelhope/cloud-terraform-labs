# SmartFactory IoT refactor

This is a working Terraform example from my cloud architecture optimization coursework.

The exercise started with 10,000 factory sensors and an oversized AWS setup. I explored how to right-size Kinesis, Lambda, RDS, S3, Glue and Redshift without removing the streaming flow.

Highlights:
- Reduced the proposed Kinesis shard count from 1,000 to 8.
- Moved historical sensor readings toward S3 while retaining recent readings for the operational database.
- Added more specific IAM permissions and encryption settings.
- Used scheduled data processing rather than keeping reporting capacity on all day.

This repository keeps an **earlier working version of the Terraform refactor** together with the supporting Python and SQL examples. It is not the final submitted 780-line Terraform revision, and it has **not been deployed or load-tested**.

## Before running Terraform

The code references a generated Lambda ZIP. Build it locally first (requires Python, `pip`, and `zip`):

```sh
sh build_lambda_package.sh
terraform fmt -check
terraform init -backend=false
terraform validate
```

The dashboard API file is included as a supporting example, but this earlier Terraform version does not provision its API Gateway resources. The exact final coursework version passed local `terraform validate` on my Mac; this earlier copy should be validated separately before being used.

**Important:** `terraform apply` may provision billable AWS resources. Review the configuration and provide credentials securely before using it.
