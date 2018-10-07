#!/usr/bin/perl

use strict;
use warnings;

use File::Which;
use File::Temp qw/ tempfile/;
use JSON qw/decode_json/;

my $awsCli = which("aws");

if (! -x $awsCli) {
  die "$0: aws cli tool not installed. Exiting.";
}

my $workingDir = "generated";

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

&generateSSHConfig();
&generateKubeConfig();
# Must be after Kube config otherwise kubectl can't contact cluster
&joinKubeCluster();

exit 0;

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

  my $kubeConfig = qq{
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
  name: aws
current-context: aws
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
  my $configFile = "$ENV{HOME}/.kube/config-${clusterName}";
  writeToFile($configFile, $kubeConfig);
  print "Kubernetes cluster config file written to: $configFile\n";
}

sub generateSSHConfig() {

  print "Creating AWS bastion SSH config file...\n";

  my (%bastionObj, %webserverA, %webserverB);
  for my $ec2InstanceReg (@ec2Instances) {
    my %ec2Instance = %{$ec2InstanceReg};
    my @tags = @{$ec2Instance{"Tags"}};
    for my $tag (@tags) {
      my $key = ${$tag}{"Key"};
      my $value = ${$tag}{"Value"};
      if ($key eq "Name") {
        if ($value eq "LinuxBastion") {
          %bastionObj = %ec2Instance;
        }
        elsif ($value eq "CoreFantasy-WebServerGroup-Node") {
          if ($ec2Instance{"Placement"}{"AvailabilityZone"} eq "us-west-2a") {
            %webserverA = %ec2Instance;
          }
          else {
            %webserverB = %ec2Instance;
          }
        }
      }
    }
  }

  my $json = `$awsCli ec2 describe-key-pairs`;
  my $keyPairsObj = decode_json($json);
  my $defaultKeyPair = ${$keyPairsObj}{"KeyPairs"}[0]{"KeyName"};

  my $defaultLocation = "$ENV{HOME}/AWS/${defaultKeyPair}.pem";
  print "Enter location of AWS key .pem file [$defaultLocation]: ";
  chomp(my $identityFile = <>);
  if (!defined $identityFile || $identityFile eq "") {
    $identityFile = $defaultLocation;
  }

  my $bastionIP = $bastionObj{"PublicIpAddress"};
  my $webserverAIP = $webserverA{"PrivateIpAddress"};
  my $webserverBIP = $webserverB{"PrivateIpAddress"};

  my $bastionHost = "Bastion";

  # See: http://www.sanjeevnandam.com/blog/ssh-to-private-machines-through-public-bastion-aws-2

  my $configData = qq{
Host $bastionHost
  Hostname $bastionIP
  User ec2-user
  IdentityFile $identityFile

Host WebserverA
  Hostname $webserverAIP
  User ec2-user
  IdentityFile $identityFile
  ProxyCommand ssh $bastionHost nc %h %p
Host WebserverB
  Hostname $webserverBIP
  User ec2-user
  IdentityFile $identityFile
  ProxyCommand ssh $bastionHost nc %h %p
  };

  my $file = "${workingDir}/ssh_config";
  writeToFile($file, $configData);
  print "SSH file written to: $file\n";
  # Not doing this manually as it's really tricky to not append duplicate entries to .ssh/config
  # If you use "ssh -A -F generated/ssh_config Webserver" authentication to the private machine fails.
  print "  --> Copy this to ~/.ssh/config or append contents to same file.\n";
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

  my ($fh, $filename) = tempfile();
  writeToFile($filename, $configMap);
  system("kubectl apply -f $filename");
}

sub writeToFile() {
  my ($file, $data) = @_;

  open FILE, ">${file}" or die "$0: Failed to open '$file' for writing: $!\n";
  print FILE $data;
  close FILE or die "$0: Failed to close '$file': $!\n";
}
