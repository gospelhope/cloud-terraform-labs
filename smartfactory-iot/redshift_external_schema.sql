-- Run once after the Gold Glue catalog database has been created.
-- Use the gold_catalog_database and spectrum_role_arn Terraform outputs.
CREATE EXTERNAL SCHEMA smartfactory_gold
FROM DATA CATALOG
DATABASE '<gold_catalog_database output>'
IAM_ROLE '<spectrum_role_arn output>'
REGION 'us-east-1';

-- After the crawler runs, list the available tables:
SELECT schemaname, tablename FROM SVV_EXTERNAL_TABLES
WHERE schemaname = 'smartfactory_gold';
