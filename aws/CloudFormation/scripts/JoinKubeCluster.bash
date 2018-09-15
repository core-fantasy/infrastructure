#!/bin/bash
set -o xtrace

ClusterName=$1 ; shift
StackName=$2 ; shift
Region=$3 ; shift

echo "Cluster: '$ClusterName'; Stack: '$StackName'; Region: '$Region'"

/etc/eks/bootstrap.sh $ClusterName $@
/opt/aws/bin/cfn-signal --exit-code $? \
                        --stack $StackName \
                        --resource NodeGroup  \
                        --region $Region
