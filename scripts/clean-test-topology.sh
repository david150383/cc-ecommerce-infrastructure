#!/usr/bin/env bash
# Deletes queues, topics and subscriptions that test runs left in the LOCAL emulator (names starting with
# "t-" or "test-"). Never touches the platform's own "local-ecommerce-*" resources. Floci only: the
# endpoint is fixed to localhost, so this cannot reach a real AWS account.
set -euo pipefail
export AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_DEFAULT_REGION=us-east-1
aws_local() { aws --endpoint-url http://localhost:4566 "$@"; }

queues=0
for url in $(aws_local sqs list-queues --output text --query 'QueueUrls[]' | tr '\t' '\n'); do
  name=${url##*/}
  [[ $name =~ ^(t|test)- ]] || continue
  aws_local sqs delete-queue --queue-url "$url"; queues=$((queues + 1))
done

topics=0
for arn in $(aws_local sns list-topics --output text --query 'Topics[].TopicArn' | tr '\t' '\n'); do
  name=${arn##*:}
  [[ $name =~ ^(t|test)- ]] || continue
  for sub in $(aws_local sns list-subscriptions-by-topic --topic-arn "$arn" --output text --query 'Subscriptions[].SubscriptionArn' | tr '\t' '\n'); do
    [[ $sub == arn:* ]] && aws_local sns unsubscribe --subscription-arn "$sub"
  done
  aws_local sns delete-topic --topic-arn "$arn"; topics=$((topics + 1))
done
echo "deleted $queues test queues and $topics test topics"
