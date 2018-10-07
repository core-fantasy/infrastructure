# infrastructure
Infrastructure data

This project contains files to stand up the infrastructure needed for core-fantasy.
Right now this means AWS.

## AWS
In the AWS directory is a script, **deployStack.pl**, which is used to upload
the Cloudformation files to an S3 bucket and deploy the stack.

This assumes you've set up **kubectl** to work with EKS (see below).

Once the stack is deployed, the **postDeploy.pl** script is used to generate
useful files (ssh config, Kubernetes config) and issue a command to the 
Kubernetes worker nodes to join the Kubernetes cluster (I couldn't figure out
how to do this automatically).

### Configuring kubectl to work with EKS
See
* https://docs.aws.amazon.com/eks/latest/userguide/getting-started.html#eks-configure-kubectl


## Dependencies
* [AWS CLI][AWS]
* Perl
  * [JSON][JSON] module
  * [File::Which][Which] module

## Miscellany
### Banners
Banners generated [here][banner] using "JS Stick Letters" font.

[AWS]: https://aws.amazon.com/cli/
[JSON]: https://metacpan.org/pod/JSON
[Which]: https://metacpan.org/pod/File::Which
[banner]: patorjk.com/software/taag/
