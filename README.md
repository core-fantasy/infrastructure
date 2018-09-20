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

[AWS]: https://aws.amazon.com/cli/
[JSON]: https://metacpan.org/pod/JSON
[Which]: https://metacpan.org/pod/File::Which
