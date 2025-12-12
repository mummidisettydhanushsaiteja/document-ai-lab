document-ai-lab
Automate Data Capture at Scale with Document AI: Challenge Lab

 ⭐ DOCUMENT AI CHALLENGE LAB – AUTOMATION SCRIPT

 🚀 How to Run the Script

 Activate Google Cloud Shell

Then copy–paste the following commands 👇

curl -LO https://raw.githubusercontent.com/mummidisettydhanushsaiteja/document-ai-lab/main/document-ai-setup.sh
sudo chmod +x document-ai-setup.sh
./document-ai-setup.sh
---

 🛠 Having Issues With Task 5?

If the dataset or invoices are not showing results, run this extra command multiple times:

export PROJECT_ID=$(gcloud config get-value core/project)
gsutil -m cp -r gs://cloud-training/gsp367/  \
~/document-ai-challenge/invoices gs://${PROJECT_ID}-input-invoices/




