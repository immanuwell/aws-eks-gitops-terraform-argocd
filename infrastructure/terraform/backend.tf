# Remote state stored in S3 with DynamoDB locking.
# Run `make bootstrap-state` to create these resources before `terraform init`.
#
# Replace the bucket name with your actual bucket created by bootstrap-state.
terraform {
  backend "s3" {
    bucket         = "eks-gitops-tfstate-471112543812"
    key            = "eks-gitops/production/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "terraform-state-lock"
    encrypt        = true

    # Enable state locking to prevent concurrent modifications
    # dynamodb_table handles distributed locking automatically
  }
}
