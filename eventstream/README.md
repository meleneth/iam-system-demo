this isn't fully automated yet, sorry
localstack isn't setup to persist the queue, so before the workers
will start you need to create the queue

test:
export TF_VAR_localstack_endpoint="http://localhost:11000"

development:
export TF_VAR_localstack_endpoint="http://localhost:11130"

production:
export TF_VAR_localstack_endpoint="http://localhost:11260"

terraform plan
terraform apply
rm -Rf .terraform
