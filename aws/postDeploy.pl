#!/usr/bin/perl

use strict;
use warnings;

use File::Which;
use File::Temp qw/tempfile/;
use Getopt::Long qw(:config auto_help);
use MIME::Base64;
use JSON qw/decode_json/;
use Term::ReadKey;

my $doGenerateSSHConfig = 0;
my $doGenerateK8sConfig = 0;
my $doJoinK8sCluster = 0;
my $doInstallTiller = 0;
my $doCreateK8sSecrets = 0;

GetOptions(
  "create-k8s-secrets" => \$doCreateK8sSecrets,
  "ssh-config"         => \$doGenerateSSHConfig,
  "k8s-config"         => \$doGenerateK8sConfig,
  "join-k8s-cluster"   => \$doJoinK8sCluster,
  "install-tiller"     => \$doInstallTiller,
)
  or die("Error in command line arguments.\n");

my $doAll = ! ($doCreateK8sSecrets || $doInstallTiller || $doJoinK8sCluster || $doGenerateK8sConfig || $doGenerateSSHConfig);


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

my $json = `aws ec2 describe-vpcs --filters Name=tag:Name,Values=core-fantasy`;
my $vpcs = decode_json($json);

my $vpcId = ${$vpcs}{"Vpcs"}[0]{"VpcId"};
#print "VPC id: $vpcId\n";

$json = `$awsCli ec2 describe-instances --filters Name=vpc-id,Values=$vpcId`;

my @ec2Instances = ();
my $ec2InstancesObj = decode_json($json);
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

exit 0;

sub createKubernetesSecrets() {
  print "Installing secrets to the Kubernets cluster...\n";

  my $username = "corefantasy";

  print "Enter hub.docker.com password for user $username: ";
  ReadMode('noecho'); # don't echo
  chomp(my $password = <STDIN>);
  ReadMode(0);
  print "\n";  # Just to pretty up things.

  $username = encode_base64($username);
  $password = encode_base64($password);

  my $dockerHubSecret = qq{
apiVersion: v1
kind: Secret
metadata:
  name: docker-hub-credentials
type: Opaque
data:
  username: $username
  password: $password
  };

  my ($fh, $filename) = tempfile($tempFileTemplate, UNLINK => 1);
  writeToFile($filename, $dockerHubSecret);

  system("$kubectlCli create -f $filename");

  # Lame-ass security
  writeToFile($filename, "");
  $dockerHubSecret = "";
  $password = "";
}

sub generateKubeConfig() {

  print "Creating Kubernetes config file...\n";

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

  print "Update your \$KUBECONFIG environment variable to include $kubernetesConfigFile\n";
  print "  > export KUBECONFIG=\${KUBECONFIG}:$kubernetesConfigFile\n";
}

sub generateSSHConfig() {

  print "Creating AWS bastion SSH config file...\n";

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
  print "SSH file written to: $file\n";
  # Not doing this manually as it's really tricky to not append duplicate entries to .ssh/config
  # If you use "ssh -A -F generated/ssh_config Webserver" authentication to the private machine fails.
  print "  --> Copy this to ~/.ssh/config or append contents to same file.\n";
}

sub installTiller() {
  print "Installing Tiller onto the Kubernetes cluster...\n";

  system("helm init");

  # Give tiller some access or something. Without this 'helm install...' gives a namespace error
  system("$kubectlCli create serviceaccount --namespace kube-system tiller");
  system("$kubectlCli create clusterrolebinding tiller-cluster-rule --clusterrole=cluster-admin --serviceaccount=kube-system:tiller");
  system("$kubectlCli patch deploy --namespace kube-system tiller-deploy -p '{\"spec\":{\"template\":{\"spec\":{\"serviceAccount\":\"tiller\"}}}}'");
}


sub joinKubeCluster() {

  print "Instructing Kube worker nodes to join cluster...\n";

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

  my ($fh, $filename) = tempfile($tempFileTemplate, UNLINK => 1);
  writeToFile($filename, $configMap);
  system("$kubectlCli apply -f $filename");
}

sub writeToFile() {
  my ($file, $data) = @_;

  open FILE, ">${file}" or die "$0: Failed to open '$file' for writing: $!\n";
  print FILE $data;
  close FILE or die "$0: Failed to close '$file': $!\n";
}
