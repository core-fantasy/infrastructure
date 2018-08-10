#!/usr/bin/perl

use strict;
use warnings;

use File::Find;
use JSON;

my $awsCli = "/usr/bin/aws";

if (! -x $awsCli) {
  die "$0: aws cli tool not installed. Exiting.";
}

my $region = "";

my @awsConfigVals = `$awsCli configure list`;
my $awsConfigured = 0;
foreach my $line (@awsConfigVals) {
  if ($line =~ /^\s*(access_key|secret_key)/) {
    $awsConfigured = 1
  }
  elsif ($line =~ /^\s*region\s+([^ 	]+).*/) {
    $region = $1;
  }
}

if (! $awsConfigured) {
  die "$0: awc cli tool is not configured. Run '$awsCli configure'. Exiting."
}

if ($region eq "") {
  print "Enter AWS region: ";
  chomp($region = <>);
}
else {
  print "Using configured region: $region\n";
}

my $defaultBucket = "core-fantasy";
my $defaultStack = "core-fantasy";

print "Enter S3 bucket name [$defaultBucket]: ";
chomp(my $bucketName = <>);
if ($bucketName eq "") {
  $bucketName = $defaultBucket;
}

print "Enter CloudFormation stack name [$defaultStack]: ";
chomp(my $stackName = <>);
if ($stackName eq "") {
  $stackName = $defaultStack;
}

my $createBucket = 0;
chomp(my $bucketHeadCheck = 
      `$awsCli s3api head-bucket --bucket '$bucketName' 2>&1`);
if ($bucketHeadCheck ne "") {
  $bucketHeadCheck =~ s/^\s*\n//; # Remove empty first line

  if ($bucketHeadCheck =~ /^.*\((\d+)\).*: (.*)$/) {
    my $code = $1;
    my $status = $2;

    if ($code eq "404") {
      $createBucket = 1;
    }
    else {
      die "Bucket '$bucketName' cannot be used: $code ($status)\n";
    }
  }
  else {
    die "$0: Error checking for bucket existence: $bucketHeadCheck\n";
  }
}


my $bucketUrl = "";
if ($createBucket) {
  print "Creating S3 bucket '$bucketName'\n";
  my $command = "$awsCli s3 mb s3://$bucketName --region $region 2>&1";
  chomp(my $bucketCreateOutput = `$command`);
  if ($bucketCreateOutput =~ /^make_bucket: (.*)/) {
    $bucketUrl = $1;
  }
  else {
     die "$0: bucket creation failed: $bucketCreateOutput\n";
  }
}
else {
  $bucketUrl = "s3://$bucketName";
}

my $baseDir = "CloudFormation";

my $status = system("$awsCli s3 sync --exclude '*~' $baseDir $bucketUrl");
if ($status != 0) {
  die "$0: Failed to upload all files to $bucketUrl. Status: $status\n";
}


my $stacksJson = `$awsCli cloudformation list-stacks`;
my $stacksObj = decode_json $stacksJson;

my %stacksHash = %$stacksObj;
my @stacks = @{$stacksHash{"StackSummaries"}};


my $cloudFormationCommand = "create-stack";
my $printCommand = "Creating";
foreach my $stackHashRef (@stacks) {
  my %stackHash = %$stackHashRef;

  if ($stackHash{"StackName"} eq $stackName) {
    # https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/using-cfn-describing-stacks.html

    my $status = $stackHash{"StackStatus"};
    if ($status eq "CREATE_FAILED" || $status eq "DELETE_COMPLETE") {
      $cloudFormationCommand = "create-stack";
      $printCommand = "Creating";
    }
    elsif ($status eq "CREATE_COMPLETE" ||
           $status eq "UPDATE_COMPLETE" || 
           $status eq "UPDATE_ROLLBACK_COMPLETE") {
      $printCommand = "Updating";
      $cloudFormationCommand = "update-stack";
    }
    else {
      # TODO: add option to delete stack, then create it in this case
      die "$0: Cannot update or create stack '$stackName' " . 
        "due to the current status of $status. Manual intervention to fix " .
        "the stack state is probably required. Most likely you'll need " . 
        "to delete the stack. Exiting.\n";
    }

    # AWS CLI appears to report the newest stack status first.
    last;
  }
}

print "$printCommand $stackName stack.\n";
my $command = "aws cloudformation $cloudFormationCommand " . 
  "--stack-name $stackName " . 
  "--capabilities CAPABILITY_IAM " .
  "--template-url https://s3.amazonaws.com/$bucketName/CoreFantasy.json " .
  "--parameters ParameterKey=BucketName,ParameterValue=$bucketName,UsePreviousValue=false";

$status = system($command);
if (0 != $status) {
  die "$0: stack creation failed. Exiting.\n";
}

exit 0;
