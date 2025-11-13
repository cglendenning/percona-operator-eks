#!/bin/bash
aws codebuild create-project \
  --name db-concierge-builder \
  --source type=NO_SOURCE \
  --artifacts type=NO_ARTIFACTS \
  --environment type=LINUX_CONTAINER,image=aws/codebuild/standard:5.0,computeType=BUILD_GENERAL1_SMALL,privilegedMode=true \
  --service-role <YOUR_CODEBUILD_ROLE_ARN> \
  --region us-east-1

# Then trigger a build:
# aws codebuild start-build --project-name db-concierge-builder --region us-east-1
