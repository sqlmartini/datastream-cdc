PROJECT_ID="amm-dataform"
REGION="us-central1"
JAR_FILE="gs://s8s_data_and_code_bucket-1001462454132/drivers/mssql-jdbc-12.4.0.jre8.jar"
JOB_FILE="gs://s8s_data_and_code_bucket-1001462454132/scripts/pyspark/spark_etl_parallel.py"
SUBNET="spark-snet"
SERVICE_ACCOUNT="cdf-lab-sa@amm-dataform.iam.gserviceaccount.com"

gcloud dataproc batches submit --project $PROJECT_ID \
    --region $REGION \
    pyspark $JOB_FILE \
    --version 2.1 \
    --jars $JAR_FILE \
    --service-account $SERVICE_ACCOUNT \
    --subnet $SUBNET