# infrastructure
Infrastructure data

This project contains files to stand up the infrastructure needed for core-fantasy.
Right now this means AWS.

## AWS
In the **aws** directory is a script, **deployStack.pl**, which is used to upload
the Cloudformation files to an S3 bucket and deploy the stack.

This assumes you've set up **kubectl** to work with EKS (see [this][Kubectl_EKS]).

Once the stack is deployed, the **postDeploy.pl** script is used to generate
useful files (ssh config, Kubernetes config) and issue commands to initialize
the Kubernetes cluster.

### Certificate Stack
The stack defined in **Certificate.yaml** stands outside of the rest of the Cloudformation
stacks. This stack should be deployed manually before running **deployStack.pl**. The reason
is to keep the certificates from being destroyed and re-created when bringing up and down the
full core-fantasy stack.

## Deploy core-fantasy
core-fantasy is managed via [Helm][Helm]. There are a number of charts, but the top-level chart
is the "core-fantasy" chart. To deploy the entirety of core-fantasy run:
```bash
$ helm dependency update core-fantasy
$ helm install --name core-fantasy core-fantasy
```

## Helpful Things
### Validation of files
* AWS Cloudformation: `aws cloudformation validate-template --template-body file://<full path to file>`
* Kubernetes Templates: `kubectl apply --validate=true --dry-run=true --filename=<file>`
* Helm: `helm lint <chart>`
### Google Sign In
* [Web Sign In Help](https://developers.google.com/identity/sign-in/web/)
* [Credentials Manager](https://console.developers.google.com/apis/credentials) (for Google Client Id)

### Banners
AWS SSH banners generated [here][banner] using "JS Stick Letters" font.

## Dependencies
* [AWS CLI][AWS]
* Perl
  * [JSON][JSON] module
  * [File::Which][Which] module
* [Helm][Helm]

[AWS]: https://aws.amazon.com/cli/
[JSON]: https://metacpan.org/pod/JSON
[Which]: https://metacpan.org/pod/File::Which
[banner]: patorjk.com/software/taag/
[Helm]: https://helm.sh/
[Kubectl_EKS]: https://docs.aws.amazon.com/eks/latest/userguide/getting-started.html#eks-configure-kubectl
