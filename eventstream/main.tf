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

resource "aws_sns_topic" "capability-changes" {
  name = "capability-changes"
}

resource "aws_sqs_queue" "capability-changes" {
  name = "capability-changes"
}

resource "aws_sns_topic_subscription" "capability-changes-capability-changes" {
  topic_arn = aws_sns_topic.capability-changes.arn
  protocol = "sqs"
  endpoint = aws_sqs_queue.capability-changes.arn
}

resource "aws_sns_topic" "group-membership-changes" {
  name = "group-membership-changes"
}

resource "aws_sqs_queue" "group-membership-changes" {
  name = "group-membership-changes"
}

resource "aws_sns_topic_subscription" "group-membership-changes-group-membership-changes" {
  topic_arn = aws_sns_topic.group-membership-changes.arn
  protocol = "sqs"
  endpoint = aws_sqs_queue.group-membership-changes.arn
}

resource "aws_sns_topic" "account-structure-changes" {
  name = "account-structure-changes"
}

resource "aws_sqs_queue" "account-structure-changes" {
  name = "account-structure-changes"
}

resource "aws_sns_topic_subscription" "account-structure-changes-account-structure-changes" {
  topic_arn = aws_sns_topic.account-structure-changes.arn
  protocol = "sqs"
  endpoint = aws_sqs_queue.account-structure-changes.arn
}
