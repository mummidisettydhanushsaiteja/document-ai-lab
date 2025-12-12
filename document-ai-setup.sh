#!/usr/bin/env bash
# document-ai-setup.sh
# Automates setup for "Automate Data Capture at Scale with Document AI: Challenge Lab"
# Usage: ./document-ai-setup.sh
set -euo pipefail

# ---------- Text styles ----------
YELLOW=$(tput setaf 3 || true)
BOLD=$(tput bold || true)
RESET=$(tput sgr0 || true)

echo
echo "${YELLOW}${BOLD}Document AI Challenge Lab - quick setup${RESET}"
echo

# ---------- Collect user input ----------
read -p "${YELLOW}${BOLD}Enter the GCP REGION (example: us-central1): ${RESET}" REGION
read -p "${YELLOW}${BOLD}Enter a DISPLAY NAME for the Document AI Processor (example: my-form-processor): ${RESET}" PROCESSOR_DISPLAY_NAME
read -p "${YELLOW}${BOLD}Enter the PARSER LOCATION for Document AI (default: us): ${RESET}" PARSER_LOCATION
PARSER_LOCATION=${PARSER_LOCATION:-us}
echo

# Export variables
export REGION PARSER_LOCATION PROCESSOR_DISPLAY_NAME

# ---------- Resolve project ----------
echo "Checking gcloud auth & project..."
gcloud auth list --filter=status:ACTIVE --format="value(account)" || true

PROJECT_ID=$(gcloud config get-value core/project 2>/dev/null || true)
if [[ -z "${PROJECT_ID}" || "${PROJECT_ID}" == "(unset)" ]]; then
  echo "No project configured in gcloud. Please run: gcloud config set project <YOUR_PROJECT_ID>"
  exit 1
fi
export PROJECT_ID
echo "Using project: ${PROJECT_ID}"
echo

# ---------- Enable required APIs ----------
echo "Enabling required APIs..."
gcloud services enable \
  documentai.googleapis.com \
  cloudfunctions.googleapis.com \
  cloudbuild.googleapis.com \
  artifactregistry.googleapis.com \
  bigquery.googleapis.com \
  storage.googleapis.com \
  --project "${PROJECT_ID}"

# small pause for APIs to be accepted
sleep 6

# ---------- Copy lab starter files ----------
WORKDIR="$HOME/document-ai-challenge"
echo "Creating workdir and copying starter files to ${WORKDIR}..."
mkdir -p "${WORKDIR}"
gsutil -m cp -r gs://spls/gsp367/* "${WORKDIR}/" || {
  echo "Warning: could not copy starter files from gs://spls/gsp367/. If this is an error please check network/permissions."
}

# ---------- Create Document AI Processor via REST (capture processor_id) ----------
echo
echo "Creating Document AI Form Parser processor in location: ${PARSER_LOCATION}"
ACCESS_TOKEN=$(gcloud auth application-default print-access-token 2>/dev/null || gcloud auth print-access-token)
if [[ -z "$ACCESS_TOKEN" ]]; then
  echo "Failed to fetch an access token. Ensure you're logged in via 'gcloud auth login' or 'gcloud auth application-default login'."
  exit 1
fi

CREATE_RESPONSE=$(curl -s -X POST \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{
    \"displayName\": \"${PROCESSOR_DISPLAY_NAME}\",
    \"type\": \"FORM_PARSER_PROCESSOR\"
  }" \
  "https://documentai.googleapis.com/v1/projects/${PROJECT_ID}/locations/${PARSER_LOCATION}/processors" )

# Try to parse processor name e.g. "projects/123/locations/us/processors/ABCDEF"
PROCESSOR_NAME=$(echo "$CREATE_RESPONSE" | grep -oP '"name"\s*:\s*"\Kprojects\/[^"]+' || true)
if [[ -z "$PROCESSOR_NAME" ]]; then
  # maybe the API returned an existing processor listing or error — try to extract id differently:
  PROCESSOR_NAME=$(echo "$CREATE_RESPONSE" | sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\(projects\/[^"]*\)".*/\1/p' || true)
fi

if [[ -z "$PROCESSOR_NAME" ]]; then
  echo "Warning: could not extract processor name from API response. Response was:"
  echo "$CREATE_RESPONSE"
  echo "You can create a processor manually in the Console and then set PROCESSOR_ID environment variable before running the deploy step."
else
  # Extract the trailing processor id
  PROCESSOR_ID="$(basename "$PROCESSOR_NAME")"
  export PROCESSOR_ID
  echo "Created processor: ${PROCESSOR_NAME}"
  echo "Processor ID: ${PROCESSOR_ID}"
fi

# ---------- Create GCS buckets ----------
INPUT_BUCKET="${PROJECT_ID}-input-invoices"
OUTPUT_BUCKET="${PROJECT_ID}-output-invoices"
ARCHIVE_BUCKET="${PROJECT_ID}-archived-invoices"

create_bucket_if_needed() {
  local bucket="$1"
  local region="$2"
  if gsutil ls -b "gs://${bucket}" >/dev/null 2>&1; then
    echo "Bucket gs://${bucket} already exists."
  else
    echo "Creating gs://${bucket} in region ${region} (uniform access, STANDARD)..."
    gsutil mb -p "${PROJECT_ID}" -c STANDARD -l "${region}" -b on "gs://${bucket}"
  fi
}

echo
echo "Creating required buckets (if absent):"
create_bucket_if_needed "${INPUT_BUCKET}" "${REGION}"
create_bucket_if_needed "${OUTPUT_BUCKET}" "${REGION}"
create_bucket_if_needed "${ARCHIVE_BUCKET}" "${REGION}"

# ---------- Create BigQuery dataset & table ----------
DATASET="invoice_parser_results"
TABLE="doc_ai_extracted_entities"
BQ_LOCATION="US"

echo
echo "Creating BigQuery dataset ${DATASET} in ${BQ_LOCATION} (if needed)..."
if bq --project_id="${PROJECT_ID}" show --format=pretty "${DATASET}" >/dev/null 2>&1; then
  echo "Dataset ${DATASET} exists."
else
  bq --location="${BQ_LOCATION}" mk --dataset --project_id="${PROJECT_ID}" "${DATASET}"
fi

SCHEMA_FILE="${WORKDIR}/scripts/table-schema/doc_ai_extracted_entities.json"
if [[ -f "${SCHEMA_FILE}" ]]; then
  echo "Creating BigQuery table ${DATASET}.${TABLE} (if absent) using schema ${SCHEMA_FILE}..."
  if bq --project_id="${PROJECT_ID}" show "${DATASET}.${TABLE}" >/dev/null 2>&1; then
    echo "Table ${DATASET}.${TABLE} already exists."
  else
    bq --location="${BQ_LOCATION}" mk --table --project_id="${PROJECT_ID}" "${DATASET}.${TABLE}" "${SCHEMA_FILE}"
  fi
else
  echo "Warning: schema file not found at ${SCHEMA_FILE}. Skipping table creation. Make sure schema is available before creating the table."
fi

# ---------- IAM roles for service accounts ----------
echo
echo "Applying required IAM roles (best-effort)..."
PROJECT_NUMBER=$(gcloud projects describe "${PROJECT_ID}" --format='value(projectNumber)')
COMPUTE_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"
CF_SA="${PROJECT_ID}@appspot.gserviceaccount.com"

# pubsub.publisher for CF SA (lab asked for it)
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${CF_SA}" --role="roles/pubsub.publisher" || true

# artifactregistry.reader for compute SA (if needed)
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${COMPUTE_SA}" --role="roles/artifactregistry.reader" || true

# ---------- Prepare Cloud Function env file ----------
CF_SOURCE="${WORKDIR}/scripts/cloud-functions/process-invoices"
ENV_FILE="${CF_SOURCE}/.env.yaml"

echo
echo "Writing env file for Cloud Function: ${ENV_FILE}"
mkdir -p "${CF_SOURCE}"
cat > "${ENV_FILE}" <<EOF
PROJECT_ID: "${PROJECT_ID}"
PROCESSOR_ID: "${PROCESSOR_ID:-}"
PARSER_LOCATION: "${PARSER_LOCATION}"
INPUT_BUCKET: "${INPUT_BUCKET}"
OUTPUT_BUCKET: "${OUTPUT_BUCKET}"
ARCHIVE_BUCKET: "${ARCHIVE_BUCKET}"
BQ_DATASET: "${DATASET}"
BQ_TABLE: "${TABLE}"
EOF

# ---------- Deploy Cloud Function (Gen2) with retries ----------
echo
echo "Deploying Cloud Function (gen2) 'process-invoices' to region ${REGION}..."
deploy_attempt=0
max_attempts=6
while (( deploy_attempt < max_attempts )); do
  deploy_attempt=$((deploy_attempt + 1))
  echo "Attempt ${deploy_attempt} of ${max_attempts}..."
  if gcloud functions deploy process-invoices \
      --gen2 \
      --region="${REGION}" \
      --entry-point=process_invoice \
      --runtime=python313 \
      --service-account="${CF_SA}" \
      --source="${CF_SOURCE}" \
      --timeout=400s \
      --env-vars-file="${ENV_FILE}" \
      --trigger-resource="gs://${INPUT_BUCKET}" \
      --trigger-event="google.storage.object.finalize" \
      --allow-unauthenticated; then
    echo "Cloud Function deployed successfully."
    break
  else
    echo "Deploy failed — retrying in 15s..."
    sleep 15
  fi
done

if (( deploy_attempt >= max_attempts )); then
  echo "Deployment failed after ${max_attempts} attempts. Check permissions and logs and re-run the script when ready."
  exit 2
fi

# ---------- Upload sample invoices (optional) ----------
INVOICE_DIR="${WORKDIR}/invoices"
if [[ -d "${INVOICE_DIR}" ]]; then
  echo "Uploading sample invoices from ${INVOICE_DIR} to gs://${INPUT_BUCKET}/"
  gsutil -m cp "${INVOICE_DIR}"/* "gs://${INPUT_BUCKET}/" || echo "Upload failed or no invoices to upload."
else
  echo "No local sample invoices found at ${INVOICE_DIR}. Skipping upload."
fi

# ---------- Final instructions ----------
echo
echo "${YELLOW}${BOLD}Setup complete (or mostly complete).${RESET}"
echo "Important next steps you may need to perform manually:"
echo "  - Verify the processor in Cloud Console: Document AI → Processors. Ensure the processor ID and location are correct."
echo "  - If processor creation failed above, create a processor in the Console and then re-run gcloud functions deploy with PROCESSOR_ID set."
echo
echo "Quick checks:"
echo "  - List processors:"
echo "    curl -H \"Authorization: Bearer \$(gcloud auth print-access-token)\" \\"
echo "      \"https://documentai.googleapis.com/v1/projects/${PROJECT_ID}/locations/${PARSER_LOCATION}/processors\""
echo
echo "  - Query BigQuery (example):"
echo "    bq query --use_legacy_sql=false 'SELECT * FROM \`${PROJECT_ID}.${DATASET}.${TABLE}\` LIMIT 10;'"
echo
echo "If you'd like, I can also prepare a README and the GitHub repo layout (README + this script) so it's ready to curl from raw.githubusercontent.com."
