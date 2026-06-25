The development eventstream uses `goaws` and loads queues/topics from
`eventstream/goaws.yaml` at startup.

Keep new SQS/SNS infrastructure in `goaws.yaml`; runtime-created queues are
only a temporary repair for the current process and will disappear on restart.

`msp_reflected_grants` is a direct SQS queue used by auth-service load requests,
not an SNS subscription from `user_seed`.

The Terraform below is kept as a secondary/manual setup path.

test:
export TF_VAR_localstack_endpoint="http://localhost:11000"

development:
export TF_VAR_localstack_endpoint="http://localhost:11130"

production:
export TF_VAR_localstack_endpoint="http://localhost:11260"

terraform plan
terraform apply
rm -Rf .terraform
