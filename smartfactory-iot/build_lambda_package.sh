#!/bin/sh
# Build the processor and dashboard handlers with the PostgreSQL driver.
set -eu
rm -rf .lambda_package
rm -f lambda_function.zip
mkdir -p .lambda_package
python3 -m venv .build_venv
.build_venv/bin/python -m pip install --disable-pip-version-check -q --target .lambda_package 'pg8000>=1.30,<2'
cp lambda_handler.py dashboard_api.py .lambda_package/
(cd .lambda_package && zip -qr ../lambda_function.zip . -x '*/__pycache__/*' '*.pyc')
echo "Built lambda_function.zip with pg8000 dependencies."
