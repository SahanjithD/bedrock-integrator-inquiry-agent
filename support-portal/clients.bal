// AWS clients. They use the default credential chain: environment variables, the shared AWS
// config and credentials files (including `AWS_PROFILE`), or SSO.

import ballerinax/aws.auth;
import ballerinax/aws.dynamodb;
import ballerinax/aws.sqs;

final dynamodb:Client caseStore = check new ({auth: auth:DEFAULT_CREDENTIALS, region: awsRegion});
final sqs:Client queues = check new ({auth: auth:DEFAULT_CREDENTIALS, region: awsRegion});
