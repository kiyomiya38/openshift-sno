# 10. コスト管理

主因は EC2、EBS、NAT Gateway、LB、Public IPv4/EIP、Route 53、data transfer、Red Hat entitlement です。停止した EC2 以外は残存課金し得ます。AWS Pricing Calculator で `ap-northeast-3`、instance、稼働時間、150 GiB gp3、NAT/LB 時間と GB、public IPv4、DNS、転送量を入力し、[EC2 On-Demand](https://aws.amazon.com/ec2/pricing/on-demand/)、[VPC pricing](https://aws.amazon.com/vpc/pricing/)、[ELB pricing](https://aws.amazon.com/elasticloadbalancing/pricing/) と照合します。

Budgets/Cost Explorer の alert を事前設定します。学習終了時は EC2 の stop/terminate ではなく [destroy](11-destroy-cluster.md) を行います。

