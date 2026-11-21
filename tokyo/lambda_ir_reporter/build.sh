#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

rm -rf build lambda_ir_reporter.zip
mkdir -p build

cp handler.py build/

# boto3/botocore ship with the Lambda Python runtime already — no
# external deps needed for this handler. If you add any later:
#   pip install -r requirements.txt -t build/

cd build
zip -r ../lambda_ir_reporter.zip .
cd ..

echo "Built lambda_ir_reporter.zip"
