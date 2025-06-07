locals {
  is_private_endpoint         = var.cirrus_api_rest_type == "PRIVATE" ? true : false
  deploy_api                  = var.deploy_api_gateway ? 1 : 0
  deploy_private_api_endpoint = var.deploy_api_gateway && local.is_private_endpoint ? 1 : 0
  deploy_api_alarms           = var.deploy_api_gateway && var.deploy_alarms ? 1 : 0
  deploy_api_domain_name      = var.deploy_api_gateway && local.is_private_endpoint && var.domain_alias != "" && var.private_certificate_arn != "" ? 1 : 0
}

resource "aws_iam_role" "cirrus_api_lambda_role" {
  name_prefix = "${var.resource_prefix}-api-role-"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      },
      "Effect": "Allow"
    }
  ]
}
EOF

}

resource "aws_iam_policy" "cirrus_api_lambda_policy" {
  name_prefix = "${var.resource_prefix}-api-policy-"

  # TODO: the secret thing is probably not gonna work without some fixes in boto3utils...
  # We should probably reconsider if this is the right solution.
  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": [
        "s3:ListBucket",
        "s3:GetObject",
        "s3:GetBucketLocation"
      ],
      "Resource": "arn:aws:s3:::${var.cirrus_data_bucket}*",
      "Effect": "Allow"
    },
    {
      "Action": "secretsmanager:GetSecretValue",
      "Resource": [
        "arn:aws:secretsmanager:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:secret:${var.resource_prefix}*"
      ],
      "Effect": "Allow"
    },
    {
      "Effect": "Allow",
      "Action": [
        "dynamodb:Query",
        "dynamodb:Scan",
        "dynamodb:GetItem",
        "dynamodb:PutItem",
        "dynamodb:UpdateItem",
        "dynamodb:DescribeTable"
      ],
      "Resource": [
        "${var.cirrus_state_dynamodb_table_arn}",
        "${var.cirrus_state_dynamodb_table_arn}/index/*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "timestream:DescribeEndpoints"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "timestream:Select"
      ],
      "Resource": "${var.cirrus_state_event_timestreamwrite_table_arn}"
    }
  ]
}
EOF

}

resource "aws_iam_role_policy_attachment" "cirrus_api_lambda_role_policy_attachment1" {
  role       = aws_iam_role.cirrus_api_lambda_role.name
  policy_arn = aws_iam_policy.cirrus_api_lambda_policy.arn
}

resource "aws_iam_role_policy_attachment" "cirrus_api_lambda_role_policy_attachment2" {
  role       = aws_iam_role.cirrus_api_lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_lambda_function" "cirrus_api" {
  filename         = var.cirrus_lambda_zip_filepath
  function_name    = "${var.resource_prefix}-api"
  description      = "Cirrus API Lambda"
  role             = aws_iam_role.cirrus_api_lambda_role.arn
  handler          = "api.lambda_handler"
  source_code_hash = filebase64sha256(var.cirrus_lambda_zip_filepath)
  runtime          = "python3.12"
  timeout          = var.cirrus_api_lambda_timeout
  memory_size      = var.cirrus_api_lambda_memory
  publish          = true
  architectures    = ["arm64"]

  environment {
    variables = {
      CIRRUS_LOG_LEVEL          = var.cirrus_log_level
      CIRRUS_DATA_BUCKET        = var.cirrus_data_bucket
      CIRRUS_PAYLOAD_BUCKET     = var.cirrus_payload_bucket
      CIRRUS_STATE_DB           = var.cirrus_state_dynamodb_table_name
      CIRRUS_EVENT_DB_AND_TABLE = "${var.cirrus_state_event_timestreamwrite_database_name}|${var.cirrus_state_event_timestreamwrite_table_name}"
    }
  }

  vpc_config {
    security_group_ids = var.vpc_security_group_ids
    subnet_ids         = var.vpc_subnet_ids
  }
}

resource "aws_security_group" "cirrus_api_gateway_private_vpce" {
  count = local.deploy_private_api_endpoint

  name_prefix = "${var.resource_prefix}-apigw-vcpe-sg-"
  description = "Allows TCP inbound on 443 from VPC private subnet CIDRs"

  vpc_id = var.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "cirrus_api_gateway_private_vpce" {
  for_each = local.deploy_private_api_endpoint == 1 ? { for s in data.aws_subnet.selected : s.id => s } : {}

  security_group_id = aws_security_group.cirrus_api_gateway_private_vpce[0].id
  description       = "Allow TCP on 443 for subnet ${each.value.id}"

  cidr_ipv4   = each.value.cidr_block
  ip_protocol = "tcp"
  from_port   = 443
  to_port     = 443
}

resource "aws_vpc_endpoint" "cirrus_api_gateway_private" {
  count = local.deploy_private_api_endpoint

  service_name        = "com.amazonaws.${data.aws_region.current.name}.execute-api"
  vpc_id              = var.vpc_id
  vpc_endpoint_type   = "Interface"
  ip_address_type     = "ipv4"
  subnet_ids          = data.aws_subnet.selected[*].id
  auto_accept         = true
  private_dns_enabled = false
  security_group_ids = concat(
    aws_security_group.cirrus_api_gateway_private_vpce[*].id,
    coalesce(var.cirrus_private_api_additional_security_group_ids, [])
  )

  dns_options {
    dns_record_ip_type = "ipv4"
  }
}

resource "aws_api_gateway_rest_api" "cirrus_api_gateway" {
  count = local.deploy_api
  name  = "${var.resource_prefix}-api"

  endpoint_configuration {
    types            = [var.cirrus_api_rest_type]
    vpc_endpoint_ids = local.is_private_endpoint ? aws_vpc_endpoint.cirrus_api_gateway_private[*].id : []
  }
}

data "aws_iam_policy_document" "cirrus_api_gateway_private" {
  count = local.deploy_private_api_endpoint

  statement {
    sid       = "DenyApiInvokeForNonVpceTraffic"
    effect    = "Deny"
    actions   = ["execute-api:Invoke"]
    resources = ["arn:aws:execute-api:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:${aws_api_gateway_rest_api.cirrus_api_gateway[0].id}/*"]

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    condition {
      variable = "aws:SourceVpce"
      test     = "StringNotEquals"
      values   = [aws_vpc_endpoint.cirrus_api_gateway_private[0].id]
    }
  }

  statement {
    sid       = "AllowApiInvoke"
    effect    = "Allow"
    actions   = ["execute-api:Invoke"]
    resources = ["arn:aws:execute-api:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:${aws_api_gateway_rest_api.cirrus_api_gateway[0].id}/*"]

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
  }
}

resource "aws_api_gateway_rest_api_policy" "cirrus_api_gateway_private" {
  count = local.deploy_private_api_endpoint

  rest_api_id = aws_api_gateway_rest_api.cirrus_api_gateway[0].id
  policy      = data.aws_iam_policy_document.cirrus_api_gateway_private[0].json
}

resource "aws_api_gateway_method" "cirrus_api_gateway_root_method" {
  count         = local.deploy_api
  rest_api_id   = aws_api_gateway_rest_api.cirrus_api_gateway[0].id
  resource_id   = aws_api_gateway_rest_api.cirrus_api_gateway[0].root_resource_id
  http_method   = "GET"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "cirrus_api_gateway_root_method_integration" {
  count                   = local.deploy_api
  rest_api_id             = aws_api_gateway_rest_api.cirrus_api_gateway[0].id
  resource_id             = aws_api_gateway_rest_api.cirrus_api_gateway[0].root_resource_id
  http_method             = aws_api_gateway_method.cirrus_api_gateway_root_method[0].http_method
  type                    = "AWS_PROXY"
  uri                     = "arn:aws:apigateway:${data.aws_region.current.name}:lambda:path/2015-03-31/functions/${aws_lambda_function.cirrus_api[0].arn}/invocations"
  integration_http_method = "POST"
}

resource "aws_api_gateway_resource" "cirrus_api_gateway_proxy_resource" {
  count       = local.deploy_api
  rest_api_id = aws_api_gateway_rest_api.cirrus_api_gateway[0].id
  parent_id   = aws_api_gateway_rest_api.cirrus_api_gateway[0].root_resource_id
  path_part   = "{proxy+}"
}

resource "aws_api_gateway_method" "cirrus_api_gateway_proxy_resource_method" {
  count         = local.deploy_api
  rest_api_id   = aws_api_gateway_rest_api.cirrus_api_gateway[0].id
  resource_id   = aws_api_gateway_resource.cirrus_api_gateway_proxy_resource[0].id
  http_method   = "GET"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "cirrus_api_gateway_proxy_resource_method_integration" {
  count                   = local.deploy_api
  rest_api_id             = aws_api_gateway_rest_api.cirrus_api_gateway[0].id
  resource_id             = aws_api_gateway_resource.cirrus_api_gateway_proxy_resource[0].id
  http_method             = aws_api_gateway_method.cirrus_api_gateway_proxy_resource_method[0].http_method
  type                    = "AWS_PROXY"
  uri                     = "arn:aws:apigateway:${data.aws_region.current.name}:lambda:path/2015-03-31/functions/${aws_lambda_function.cirrus_api[0].arn}/invocations"
  integration_http_method = "POST"
}

resource "aws_api_gateway_deployment" "cirrus_api_gateway" {
  count = local.deploy_api
  depends_on = [
    aws_api_gateway_integration.cirrus_api_gateway_root_method_integration[0],
    aws_api_gateway_integration.cirrus_api_gateway_proxy_resource_method_integration[0],
  ]

  rest_api_id       = aws_api_gateway_rest_api.cirrus_api_gateway[0].id
  stage_name        = var.cirrus_api_stage
  stage_description = var.cirrus_api_stage_description

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_cloudwatch_log_group" "cirrus_api_gateway_logs_group" {
  count = local.deploy_api
  name  = "/aws/apigateway/${var.resource_prefix}-api-${aws_api_gateway_deployment.cirrus_api_gateway[0].rest_api_id}/${aws_api_gateway_deployment.cirrus_api_gateway[0].stage_name}"
}

locals {
  access_log_format = "{\"requestId\":\"\\$context.requestId\",\"ip\":\"\\$context.identity.sourceIp\",\"caller\":\"\\$context.identity.caller\",\"user\":\"\\$context.identity.user\",\"requestTime\":\"\\$context.requestTime\",\"httpMethod\":\"\\$context.httpMethod\",\"resourcePath\":\"\\$context.resourcePath\",\"status\":\"\\$context.status\",\"protocol\":\"\\$context.protocol\",\"responseLength\":\"\\$context.responseLength\"}"
}

resource "null_resource" "enable_access_logs" {
  count = local.deploy_api
  triggers = {
    stage_name              = aws_api_gateway_deployment.cirrus_api_gateway[0].stage_name
    rest_api_id             = aws_api_gateway_deployment.cirrus_api_gateway[0].rest_api_id
    apigw_access_logs_group = aws_cloudwatch_log_group.cirrus_api_gateway_logs_group[0].arn
    access_log_format       = local.access_log_format
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-ec"]
    command     = <<EOF
export AWS_DEFAULT_REGION=${data.aws_region.current.name}
export AWS_REGION=${data.aws_region.current.name}

echo "Update Access Logging on FilmDrop Cirrus API."
aws apigateway update-stage --rest-api-id ${aws_api_gateway_deployment.cirrus_api_gateway[0].rest_api_id} --stage-name ${aws_api_gateway_deployment.cirrus_api_gateway[0].stage_name} --patch-operations "[{\"op\": \"replace\",\"path\": \"/accessLogSettings/destinationArn\",\"value\": \"${aws_cloudwatch_log_group.cirrus_api_gateway_logs_group[0].arn}\"},{\"op\": \"replace\",\"path\": \"/accessLogSettings/format\",\"value\": \"${local.access_log_format}\"}]"

EOF
  }
}

resource "aws_lambda_permission" "cirrus_api_gateway_lambda_permission_root_resource" {
  count         = local.deploy_api
  statement_id  = "AllowExecutionFromAPIGatewayRootResource"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.cirrus_api.arn
  principal     = "apigateway.amazonaws.com"

  source_arn = "arn:aws:execute-api:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:${aws_api_gateway_rest_api.cirrus_api_gateway[0].id}/*/*"
}

resource "aws_lambda_permission" "cirrus_api_gateway_lambda_permission_proxy_resource" {
  count         = local.deploy_api
  statement_id  = "AllowExecutionFromAPIGatewayProxyResource"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.cirrus_api.arn
  principal     = "apigateway.amazonaws.com"

  source_arn = "arn:aws:execute-api:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:${aws_api_gateway_rest_api.cirrus_api_gateway[0].id}/*/*${aws_api_gateway_resource.cirrus_api_gateway_proxy_resource[0].path}"
}

resource "aws_cloudwatch_metric_alarm" "cirrus_api_lambda_errors_warning_alarm" {
  count = local.deploy_api_alarms

  alarm_name                = "WARNING: ${var.resource_prefix}-api Lambda Errors Warning Alarm"
  comparison_operator       = "GreaterThanOrEqualToThreshold"
  evaluation_periods        = 5
  metric_name               = "Errors"
  namespace                 = "AWS/Lambda"
  period                    = 60
  statistic                 = "Sum"
  threshold                 = 10
  treat_missing_data        = "notBreaching"
  alarm_description         = "${var.resource_prefix}-api Cirrus Update-State Lambda Errors Warning Alarm"
  alarm_actions             = [var.warning_sns_topic_arn]
  ok_actions                = [var.warning_sns_topic_arn]
  insufficient_data_actions = []

  dimensions = {
    FunctionName = aws_lambda_function.cirrus_api.function_name
  }
}

resource "aws_cloudwatch_metric_alarm" "cirrus_api_lambda_errors_critical_alarm" {
  count = local.deploy_api_alarms

  alarm_name                = "CRITICAL: ${var.resource_prefix}-api Lambda Errors Critical Alarm"
  comparison_operator       = "GreaterThanOrEqualToThreshold"
  evaluation_periods        = 5
  metric_name               = "Errors"
  namespace                 = "AWS/Lambda"
  period                    = 60
  statistic                 = "Sum"
  threshold                 = 100
  treat_missing_data        = "notBreaching"
  alarm_description         = "${var.resource_prefix}-api Cirrus Update-State Lambda Errors Critical Alarm"
  alarm_actions             = [var.critical_sns_topic_arn]
  ok_actions                = [var.warning_sns_topic_arn]
  insufficient_data_actions = []

  dimensions = {
    FunctionName = aws_lambda_function.cirrus_api.function_name
  }
}

resource "aws_cloudwatch_metric_alarm" "cirrus_api_gw_errors_warning_alarm" {
  count = local.deploy_api_alarms

  alarm_name                = "WARNING: ${aws_api_gateway_rest_api.cirrus_api_gateway[0].name} API Gateway 5XX Errors Warning Alarm"
  comparison_operator       = "GreaterThanOrEqualToThreshold"
  evaluation_periods        = 5
  metric_name               = "5XXError"
  namespace                 = "AWS/ApiGateway"
  period                    = 60
  statistic                 = "Sum"
  threshold                 = 10
  treat_missing_data        = "notBreaching"
  alarm_description         = "${aws_api_gateway_rest_api.cirrus_api_gateway[0].name} Cirrus API Gateway 5XX Errors Warning Alarm"
  alarm_actions             = [var.warning_sns_topic_arn]
  ok_actions                = [var.warning_sns_topic_arn]
  insufficient_data_actions = []

  dimensions = {
    FunctionName = aws_api_gateway_rest_api.cirrus_api_gateway[0].name
  }
}

resource "aws_cloudwatch_metric_alarm" "cirrus_api_gw_errors_critical_alarm" {
  count                     = local.deploy_api_alarms
  alarm_name                = "CRITICAL: ${aws_api_gateway_rest_api.cirrus_api_gateway[0].name} API Gateway 5XX Errors Critical Alarm"
  comparison_operator       = "GreaterThanOrEqualToThreshold"
  evaluation_periods        = 5
  metric_name               = "5XXError"
  namespace                 = "AWS/ApiGateway"
  period                    = 60
  statistic                 = "Sum"
  threshold                 = 100
  treat_missing_data        = "notBreaching"
  alarm_description         = "${aws_api_gateway_rest_api.cirrus_api_gateway[0].name} Cirrus API Gateway 5XX Errors Critical Alarm"
  alarm_actions             = [var.critical_sns_topic_arn]
  ok_actions                = [var.warning_sns_topic_arn]
  insufficient_data_actions = []

  dimensions = {
    FunctionName = aws_api_gateway_rest_api.cirrus_api_gateway[0].name
  }
}

resource "aws_api_gateway_domain_name" "cirrus_api_gateway_domain_name" {
  count           = local.deploy_api_domain_name
  certificate_arn = var.private_certificate_arn
  domain_name     = var.domain_alias

  endpoint_configuration {
    types = ["PRIVATE"]
  }

  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": "*",
      "Action": "execute-api:Invoke",
      "Resource": "arn:aws:execute-api:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:/domainnames/*"
    },
    {
      "Effect": "Deny",
      "Principal": "*",
      "Action": "execute-api:Invoke",
      "Resource": "arn:aws:execute-api:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:/domainnames/*",
      "Condition": {
        "StringNotEquals": {
          "aws:SourceVpce": "${aws_vpc_endpoint.cirrus_api_gateway_private[0].id}"
        }
      }
    }
  ]
}
EOF
}

resource "aws_api_gateway_domain_name_access_association" "cirrus_api_gateway_domain_name_access_association" {
  count                          = local.deploy_api_domain_name
  access_association_source      = aws_vpc_endpoint.cirrus_api_gateway_private[0].id
  access_association_source_type = "VPCE"
  domain_name_arn                = aws_api_gateway_domain_name.cirrus_api_gateway_domain_name[0].arn
}

resource "aws_api_gateway_base_path_mapping" "cirrus_api_gateway_domain_mapping" {
  count          = local.deploy_api_domain_name
  domain_name    = aws_api_gateway_domain_name.cirrus_api_gateway_domain_name[0].domain_name
  domain_name_id = aws_api_gateway_domain_name.cirrus_api_gateway_domain_name[0].domain_name_id
  api_id         = aws_api_gateway_rest_api.cirrus_api_gateway[0].id
  stage_name     = aws_api_gateway_deployment.cirrus_api_gateway[0].stage_name
}