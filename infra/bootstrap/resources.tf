resource "aws_s3_bucket" "terraform_state" {
  bucket = "reactor-${data.aws_caller_identity.current.account_id}-us-east-2-an"
  tags = {
    name        = "terraform-state-bucket"
    environment = "production"
  }
  lifecycle { prevent_destroy = true }
}

resource "aws_s3_bucket_versioning" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state_bucket.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state_bucket.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state_bucket.id

  rule {
    bucket_key_enabled = true
    apply_server_side_encryption_by_default {
      kms_master_key_id = aws_kms_key.mykey.arn
      sse_algorithm     = "aws:kms"
    }
  }
}

resource "aws_kms_key" "master" {
  description = "KMS key for the terraform state s3 bucket"
  deletion_window_in_days = 30
  enable_key_rotation = true
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{
      Sid       = "Enable Root Account Access"
      Effect    = "Allow"
      Principal = {
        AWS = "arn:aws:iam:${data.aws_caller_identity.current.account_id}:root"
      }
      Action    = "kms:*"
      Resource  = "*"
    }]
  })
}

resource "aws_kms_alias" "master_key_alias" {
  target_key_id = aws_kms_key.master
  name          = "alias/terraform-state-master-key"
}
