# Rol OIDC dedicado para construir AMIs con Packer en la cuenta network.
#
# Por que existe un rol propio y no se reusa GitHubActions-PlatformInfra:
# ese rol esta acotado con `job_workflow_ref` a los tres workflows reusables
# de la lib, a proposito, para que un workflow suelto en cualquier repo no
# pueda obtener credenciales de la cuenta de management. El build de la AMI es
# un workflow propio del repo, asi que queda afuera de ese rol por diseno, y
# agregarlo ahi debilitaria la puerta que entra a todas las cuentas.
#
# Este rol replica el patron que ya usa el AMI de runners en shared-services:
# OIDC directo en la cuenta donde se construye, permisos solo de Packer, y el
# trust acotado al repo Y al archivo de workflow concreto.

locals {
  tags = merge(var.tags, {
    ManagedBy = "terraform"
    Module    = "github-oidc-ami"
  })
}

# Un provider por cuenta. La cuenta network no tenia ninguno: se entraba
# siempre por role chaining desde management.
module "github_oidc_provider" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-github-oidc-provider"
  version = "~> 5.0"

  tags = local.tags
}

data "aws_iam_policy_document" "trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [module.github_oidc_provider.arn]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_org}/${var.github_repository}:*"]
    }

    # El archivo de workflow exacto: un workflow nuevo en el mismo repo no
    # hereda estas credenciales.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:job_workflow_ref"
      values   = var.trusted_workflow_refs
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  name                 = var.role_name
  description          = "GitHub Actions - Packer AMI builds in the network account"
  assume_role_policy   = data.aws_iam_policy_document.trust.json
  max_session_duration = 3600

  tags = local.tags
}

# Permisos de Packer: levanta una instancia efimera, la provisiona por SSH y
# registra la imagen. No hay iam:PassRole porque el builder no lleva instance
# profile.
data "aws_iam_policy_document" "packer" {
  statement {
    sid    = "PackerBuild"
    effect = "Allow"
    actions = [
      "ec2:DescribeImages",
      "ec2:DescribeInstances",
      "ec2:DescribeInstanceStatus",
      "ec2:DescribeInstanceTypeOfferings",
      "ec2:DescribeRegions",
      "ec2:DescribeSubnets",
      "ec2:DescribeVpcs",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeTags",
      "ec2:DescribeVolumes",
      "ec2:DescribeSnapshots",
      "ec2:DescribeKeyPairs",
      "ec2:RunInstances",
      "ec2:StopInstances",
      "ec2:TerminateInstances",
      "ec2:CreateKeyPair",
      "ec2:DeleteKeyPair",
      "ec2:CreateSecurityGroup",
      "ec2:DeleteSecurityGroup",
      "ec2:AuthorizeSecurityGroupIngress",
      "ec2:RevokeSecurityGroupIngress",
      "ec2:CreateTags",
      "ec2:DeleteTags",
      "ec2:CreateImage",
      "ec2:RegisterImage",
      "ec2:DeregisterImage",
      "ec2:CreateSnapshot",
      "ec2:DeleteSnapshot",
      "ec2:CopyImage",
      "ec2:ModifyImageAttribute",
      "ec2:ModifySnapshotAttribute",
      "ec2:ModifyInstanceAttribute",
      "ec2:GetDefaultCreditSpecification",
    ]
    resources = ["*"]
  }

  # El root volume se cifra con la clave EBS por defecto de la cuenta. Sin
  # CreateGrant el snapshot de la imagen falla.
  statement {
    sid    = "EbsDefaultKey"
    effect = "Allow"
    actions = [
      "kms:CreateGrant",
      "kms:Decrypt",
      "kms:DescribeKey",
      "kms:GenerateDataKey",
      "kms:GenerateDataKeyWithoutPlaintext",
      "kms:ReEncryptFrom",
      "kms:ReEncryptTo",
    ]
    resources = ["*"]
  }

  # Publicar el id de la AMI recien construida. El modulo headscale-server lee
  # este parametro, asi que escribirlo es lo que pone la imagen en servicio.
  statement {
    sid       = "PublishAmiId"
    effect    = "Allow"
    actions   = ["ssm:PutParameter", "ssm:GetParameter", "ssm:AddTagsToResource"]
    resources = [for p in var.ssm_parameter_paths : "arn:aws:ssm:*:${data.aws_caller_identity.current.account_id}:parameter${p}"]
  }
}

data "aws_caller_identity" "current" {}

resource "aws_iam_role_policy" "packer" {
  name   = "${var.role_name}-policy"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.packer.json
}
