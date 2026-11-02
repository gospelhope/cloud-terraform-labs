# S3 / Glue IAM review

A small Terraform example based on my earlier security review of an S3 data lake. The original Glue policy used `s3:*` on `*`, which was more access than the job needed.

This version separates read access to Bronze from write access to Silver. Bucket names and the Glue role name are inputs. It **assumes those resources already exist**, and it doesn't deploy a full data lake.

One thing I learned while reviewing this: whether Glue needs `s3:DeleteObject` depends on how the job replaces or cleans up its output. The variable `glue_needs_silver_delete` makes that choice explicit rather than silently adding or removing permission.

To check the configuration locally:

```sh
terraform init -backend=false
terraform validate
```

To deploy it, you would need to provide actual role/bucket names and AWS credentials through a secure credential provider. I have not deployed this standalone example.
