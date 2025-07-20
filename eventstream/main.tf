terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

variable "localstack_endpoint" {}

provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true

  endpoints {
    sqs = var.localstack_endpoint
    sns = var.localstack_endpoint
  }
}

resource "aws_sns_topic" "user_seed" {
  name = "user_seed"
}

resource "aws_sqs_queue" "organization_create" {
  name = "organization_create"
}

resource "aws_sqs_queue" "account_create" {
  name = "account_create"
}

resource "aws_sqs_queue" "user_create" {
  name = "user_create"
}

resource "aws_sqs_queue" "grants_create" {
  name = "grants_create"
}

resource "aws_sns_topic_subscription" "organization_create" {
  topic_arn = aws_sns_topic.user_seed.arn
  protocol = "sqs"
  endpoint = aws_sqs_queue.organization_create.arn
}

resource "aws_sns_topic_subscription" "account_create" {
  topic_arn = aws_sns_topic.user_seed.arn
  protocol = "sqs"
  endpoint = aws_sqs_queue.account_create.arn
}

resource "aws_sns_topic_subscription" "user_create" {
  topic_arn = aws_sns_topic.user_seed.arn
  protocol = "sqs"
  endpoint = aws_sqs_queue.user_create.arn
}

resource "aws_sns_topic_subscription" "grants_create" {
  topic_arn = aws_sns_topic.user_seed.arn
  protocol = "sqs"
  endpoint = aws_sqs_queue.grants_create.arn
}

