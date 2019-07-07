#!/usr/bin/perl

use strict;
use warnings;

use File::Which;
use File::Temp qw/tempfile/;
use Getopt::Long qw(:config auto_help);
use MIME::Base64;
use JSON qw/decode_json/;
use Term::ReadKey;
use Term::ANSIColor;

my $doGenerateSSHConfig = 0;
my $doGenerateK8sConfig = 0;
my $doJoinK8sCluster = 0;
my $doInstallTiller = 0;
my $doCreateK8sSecrets = 0;
my $doDatabaseSetup = 0;

Getopt::Long::GetOptions(
  "create-k8s-secrets" => \$doCreateK8sSecrets,
  "db-setup"           => \$doDatabaseSetup,
  "ssh-config"         => \$doGenerateSSHConfig,
  "k8s-config"         => \$doGenerateK8sConfig,
  "join-k8s-cluster"   => \$doJoinK8sCluster,
  "install-tiller"     => \$doInstallTiller,
)
  or die("Error in command line arguments.\n");

my $doAll = ! ($doCreateK8sSecrets || $doInstallTiller || $doJoinK8sCluster || $doGenerateK8sConfig
  || $doGenerateSSHConfig || $doDatabaseSetup);


my $awsCli = which("aws");
if (! -x $awsCli) {
  die "$0: aws cli tool not installed. Exiting.";
}

my $kubectlCli = which("kubectl");
if (! -x $kubectlCli) {
  die "$0: kubectl tool not installed Exiting.";
}

my $workingDir = "generated";
my $tempFileTemplate = "postDeployXXXXX";

my @manualPostSteps = ();

my $vpcJson = `aws ec2 describe-vpcs --filters Name=tag:Name,Values=core-fantasy`;
my $vpcs = decode_json($vpcJson);

my $vpcId = ${$vpcs}{"Vpcs"}[0]{"VpcId"};
#print "VPC id: $vpcId\n";

my $ec2Json = `$awsCli ec2 describe-instances --filters Name=vpc-id,Values=$vpcId`;

my @ec2Instances = ();
my $ec2InstancesObj = decode_json($ec2Json);
my @ec2Reservations = @{${$ec2InstancesObj}{"Reservations"}};
foreach my $ec2Reservation (@ec2Reservations) {
  my @instances = @{${$ec2Reservation}{"Instances"}};
  foreach my $instance (@instances) {
    push @ec2Instances, $instance;
  }
}

my $kubernetesConfigFile = "";

if ($doAll || $doGenerateSSHConfig) {
  &generateSSHConfig();
}
if ($doAll || $doGenerateK8sConfig) {
  &generateKubeConfig();
}
if ($doAll || $doJoinK8sCluster) {
  # Must be after Kube config otherwise kubectl can't contact cluster
  &joinKubeCluster();
}
if ($doAll || $doInstallTiller) {
  &installTiller();
}
if ($doAll || $doCreateK8sSecrets) {
  &createKubernetesSecrets();
}
if ($doAll || $doDatabaseSetup) {
  &databaseSetup();
}

&printManualSteps();

exit 0;

sub printStep($) {
  my ($banner) = @_;

  print color('bold green') . "\n$banner\n" . ("=" x length($banner)) . "\n" . color('reset');
}

sub databaseSetup() {
  printStep "Performing Database setup steps";

  my $json = `$awsCli rds describe-db-instances`;
  my $instancesObj = decode_json($json);
  my @instances = @{${$instancesObj}{"DBInstances"}};

  my $databaseConfigMap = qq{
apiVersion: v1
kind: ConfigMap
metadata:
  name: database-config
  namespace: default
data:
};

  my @databaseCreateSteps = ("ssh to the bastion host and run the following commands");
  for my $instance (@instances) {
    my $identifier = ${$instance}{"DBInstanceIdentifier"};
    my $dbUserName = ${$instance}{"MasterUsername"};
    my $address = ${$instance}{"Endpoint"}{"Address"};
    my $port = ${$instance}{"Endpoint"}{"Port"};
    # This pretty much locks us into Postgres. See https://vladmihalcea.com/jdbc-driver-connection-url-strings/
    $databaseConfigMap .=
      "  ${identifier}.address: \"//${address}:${port}\"\n" .
      "  ${identifier}.user-name: \"${dbUserName}\"\n";

    push @databaseCreateSteps, "  createdb -h ${address} -p ${port} -U ${dbUserName} user \"DB of registered users\""
  }

  my (undef, $filename) = tempfile($tempFileTemplate, UNLINK => 1);
  writeToFile($filename, $databaseConfigMap);

  system("$kubectlCli create -f $filename");


  # Manual steps
  push @manualPostSteps, [@databaseCreateSteps];
}

sub createKubernetesSecrets() {
  printStep "Installing secrets to the Kubernetes cluster";

  my $data;

  print "Enter Google Client ID: ";
  chomp(my $googleId = <>);
  $data = "  id: " . encode_base64($googleId, "");
  &createSecret("google-id", $data);

  print "Enter JWT generator secret (min 256 bits/32 chars): ";
  chomp(my $jwtGeneratorSecret = <>);
  $data = "  generator-secret: " . encode_base64($jwtGeneratorSecret, "");
  &createSecret("jwt", $data);

  my $username = "corefantasy";
  print "Enter hub.docker.com password for user $username: ";
  chomp(my $password = <STDIN>);
  $data = "  username: " . encode_base64($username, "") . "\n" .
    "  password: " . encode_base64($password, "") . "\n";
  &createSecret("docker-hub-credentials", $data);

  print "Enter 'main' DB master password (same as deploy): ";
  chomp(my $dbMasterPassword = <>);
  $data = "  password: " . encode_base64($dbMasterPassword, "");
  &createSecret("main-db-master-password", $data);
}

sub generateKubeConfig() {

  printStep "Creating Kubernetes config file";

  my $json = `$awsCli eks list-clusters`;
  my $clustersObj = decode_json($json);
  my @clusters = @{${$clustersObj}{"clusters"}};

  my $clusterName = "";
  if (scalar(@clusters) == 1) {
    $clusterName = $clusters[0];
  }
  else {
    do {
      print "Select cluster number: \n";
      for (my $ii = 0; $ii < $#clusters; ++$ii) {
        print "  $ii $clusters[$ii]\n";
      }
      chomp (my $index = <> );
      if ($index >= 0 && $index <= $#clusters) {
        $clusterName = $clusters[$index];
      }
    } while ($clusterName eq "");
  }

  $json = `$awsCli eks describe-cluster --name $clusterName`;

  my %clusterObj = %{${decode_json($json)}{"cluster"}};

  my $clusterAddress = $clusterObj{"endpoint"};
  my $clusterCA = $clusterObj{"certificateAuthority"}{"data"};
  my $clusterID = $clusterObj{"name"};

  my $context = "aws";
  my $kubeConfigData = qq{
apiVersion: v1
clusters:
- cluster:
    server: $clusterAddress
    certificate-authority-data: $clusterCA
  name: kubernetes
contexts:
- context:
    cluster: kubernetes
    user: aws
  name: $context
current-context: $context
kind: Config
preferences: {}
users:
- name: aws
  user:
    exec:
      apiVersion: client.authentication.k8s.io/v1alpha1
      command: aws-iam-authenticator
      args:
        - "token"
        - "-i"
        - "$clusterID"
        #- "-r"
        #- ""
        # env:
        # - name: AWS_PROFILE
        #   value: "<aws-profile>"
};
  $kubernetesConfigFile = "$ENV{HOME}/.kube/config-${clusterName}";
  writeToFile($kubernetesConfigFile, $kubeConfigData);
  print "Kubernetes cluster config file written to: $kubernetesConfigFile\n";

  print "Setting Kubernetes context to '$context'\n";
  system("$kubectlCli --kubeconfig='$kubernetesConfigFile' config set-context aws");

  push @manualPostSteps, [
    "Update your \$KUBECONFIG environment variable to include $kubernetesConfigFile",
    "  > export KUBECONFIG=\${KUBECONFIG}:$kubernetesConfigFile"];
}

sub generateSSHConfig() {

  printStep "Creating AWS bastion SSH config file";

  my $json = `$awsCli ec2 describe-key-pairs`;
  my $keyPairsObj = decode_json($json);
  my $defaultKeyPair = ${$keyPairsObj}{"KeyPairs"}[0]{"KeyName"};

  my $defaultLocation = "$ENV{HOME}/AWS/${defaultKeyPair}.pem";
  print "Enter location of AWS key .pem file [$defaultLocation]: ";
  chomp(my $identityFile = <>);
  if (!defined $identityFile || $identityFile eq "") {
    $identityFile = $defaultLocation;
  }

  my $configData = "";
  my $username = "ec2-user";
  my $bastionHost = "";
  my $otherNodeConfigData = "";

  for my $ec2InstanceReg (@ec2Instances) {
    my %ec2Instance = %{$ec2InstanceReg};
    my @tags = @{$ec2Instance{"Tags"}};
    for my $tag (@tags) {
      my $key = ${$tag}{"Key"};
      my $value = ${$tag}{"Value"};
      if ($key eq "Name") {

        if ($value eq "LinuxBastion") {
          $bastionHost = "$value";
          $configData .= "Host $bastionHost\n" .
            "Hostname $ec2Instance{'PublicIpAddress'}\n" .
            "User $username\n" .
            "IdentityFile $identityFile\n\n";
        }
        else {
          my $ipAddress = $ec2Instance{"PrivateIpAddress"};
          $otherNodeConfigData .= "Host ${value}-${ipAddress}\n" .
            "Hostname $ipAddress\n" .
            "User $username\n" .
            "IdentityFile $identityFile\n" .
            "ProxyCommand ssh __BASTION_HOST__ nc %h %p\n\n";
        }
      }
    }
  }

  $otherNodeConfigData =~ s/__BASTION_HOST__/$bastionHost/g;
  $configData .= $otherNodeConfigData;

  my $file = "${workingDir}/ssh_config";
  writeToFile($file, $configData);
  # Not doing this manually as it's really tricky to not append duplicate entries to .ssh/config
  # If you use "ssh -A -F generated/ssh_config Webserver" authentication to the private machine fails.
  push @manualPostSteps, ["Copy $file to ~/.ssh/config or append contents to same file."];
}

sub installTiller() {
  printStep "Installing Tiller onto the Kubernetes cluster";

  system("helm init");

  # Give tiller some access or something. Without this 'helm install...' gives a namespace error
  system("$kubectlCli create serviceaccount --namespace kube-system tiller");
  system("$kubectlCli create clusterrolebinding tiller-cluster-rule --clusterrole=cluster-admin --serviceaccount=kube-system:tiller");
  system("$kubectlCli patch deploy --namespace kube-system tiller-deploy -p '{\"spec\":{\"template\":{\"spec\":{\"serviceAccount\":\"tiller\"}}}}'");
}


sub joinKubeCluster() {

  printStep "Instructing Kube worker nodes to join cluster";

  my $json = `$awsCli iam list-roles`;
  my $rolesObj = decode_json($json);
  my @roles = @{${$rolesObj}{"Roles"}};

  my $instanceRoleARN = "";
  foreach my $roleRef (@roles) {
    my %role = %{$roleRef};
    if ($role{"RoleName"} =~ /NodeInstanceRole/) {
      $instanceRoleARN = $role{"Arn"};
    }
  }

  my $configMap = qq{
apiVersion: v1
kind: ConfigMap
metadata:
  name: aws-auth
  namespace: kube-system
data:
  mapRoles: |
    - rolearn: "$instanceRoleARN"
      username: system:node:{{EC2PrivateDNSName}}
      groups:
        - system:bootstrappers
        - system:nodes
    };

  my (undef, $filename) = tempfile($tempFileTemplate, UNLINK => 1);
  writeToFile($filename, $configMap);
  system("$kubectlCli apply -f $filename");
}

sub printManualSteps() {
  printStep "Manual Steps to Run";
  for my $ii (0..$#manualPostSteps) {
    print(($ii+1) . ".");
    for my $line (@{$manualPostSteps[$ii]}) {
      print " $line\n";
    }
  }
}

sub writeToFile() {
  my ($file, $data) = @_;

  open FILE, ">${file}" or die "$0: Failed to open '$file' for writing: $!\n";
  print FILE $data;
  close FILE or die "$0: Failed to close '$file': $!\n";
}

sub createSecret() {
  my ($secretName, $data) = @_;

  my $secret = qq{
apiVersion: v1
kind: Secret
metadata:
  name: ${secretName}
type: Opaque
data:
$data
  };

  my (undef, $filename) = tempfile($tempFileTemplate, UNLINK => 1);
  &writeToFile($filename, $secret);
  system("$kubectlCli create -f $filename");
}