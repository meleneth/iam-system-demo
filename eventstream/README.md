this isn't fully automated yet, sorry
export TF_VAR_localstack_endpoint="http://localhost:11000"
terraform plan
terraform apply
rm -Rf .terraform
