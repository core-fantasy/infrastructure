# infrastructure
Infrastructure data


## Configuring kubectl to work with EKS
See
* https://docs.aws.amazon.com/eks/latest/userguide/getting-started.html#eks-configure-kubectl

Update the data in .kube/config-CoreFantasyEKSCluster with data for the EKS cluster.
* cluster and certificate data can be found on EKS page in the AWS Console
* cluster ID in call to aws-iam-authenticator (-i argument) is the cluster ID 
(i.e., "CoreFantasyEKSCluster") also found on the EKS page
 
(TODO: figure out a way to generate this info during deployment)


## Dependencies
* [AWS CLI][AWS]
* Perl
  * [JSON][JSON] module
  * [File::Which][Which] module

## Miscellany
### SSH Bastion
To access private subnet EC2 instances, set **.ssh/config** to:
```
# Basion host
Host 54.201.206.106
  Hostname 54.201.206.106
  User ec2-user
  IdentityFile <Path to AWS Key pair, local machine>
 
# Pivate Subnet EC2 IP
# To connect to the machine run: ssh -A 10.0.6.209
Host 10.0.6.209
  Hostname 10.0.6.209
  User ec2-user
  IdentityFile <Path to AWS Key Pair, local machine>
  ProxyCommand ssh 54.201.206.106 nc %h %p 2> /dev/null
```
(There are better ways to do this.)
### Banners
Banners generated [here][banner] using "JS Stick Letters" font.

[AWS]: https://aws.amazon.com/cli/
[JSON]: https://metacpan.org/pod/JSON
[Which]: https://metacpan.org/pod/File::Which
[banner]: patorjk.com/software/taag/
