# 99. 公式資料

実装時はブログや古い版のコマンドをそのまま転用せず、OpenShift 4.21とAWSの現行公式資料を基準にします。

## Red Hat

- [OpenShift Container Platform 4.21: Installing on any platform](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html-single/installing_on_any_platform/index)
- [OpenShift Container Platform 4.21: Installing on bare metal](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html-single/installing_on_bare_metal/index)
- [User-provisioned infrastructureのDNS要件](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html/installing_on_bare_metal/user-provisioned-infrastructure#installation-user-infra-machines-advanced)
- [User-provisioned infrastructureのロードバランサー要件](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html/installing_on_bare_metal/user-provisioned-infrastructure)
- [OpenShift 4.21 Documentation](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21)
- [OpenShift 4.21: Persistent storage using NFS](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html/storage/configuring-persistent-storage#persistent-storage-nfs)
- [OpenShift 4.21: Managing security context constraints](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html/authentication_and_authorization/managing-pod-security-policies)
- [OpenShift 4.21: Working with nodes](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html/nodes/working-with-nodes)
- [OpenShift 4.21: Backing up and restoring etcd](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html/backup_and_restore/control-plane-backup-and-restore)
- [Red Hat Hybrid Cloud Console: Downloads](https://console.redhat.com/openshift/downloads)
- [Red Hat Hybrid Cloud Console: Pull Secret](https://console.redhat.com/openshift/install/pull-secret)
- [Ignition supported platforms](https://coreos.github.io/ignition/supported-platforms/)
- [Ignition configuration specification](https://coreos.github.io/ignition/configuration-v3_4/)

## Kubernetes SIG Storage

- [NFS Subdir External Provisioner](https://github.com/kubernetes-sigs/nfs-subdir-external-provisioner)
- [NFS Subdir External Provisioner license (Apache-2.0)](https://github.com/kubernetes-sigs/nfs-subdir-external-provisioner/blob/master/LICENSE)
- [Upstream deployment manifest, release 4.0.18 (application image v4.0.2)](https://github.com/kubernetes-sigs/nfs-subdir-external-provisioner/blob/nfs-subdir-external-provisioner-4.0.18/deploy/deployment.yaml)
- [Upstream RBAC manifest, release 4.0.18](https://github.com/kubernetes-sigs/nfs-subdir-external-provisioner/blob/nfs-subdir-external-provisioner-4.0.18/deploy/rbac.yaml)
- [Kubernetes Storage Classes](https://kubernetes.io/docs/concepts/storage/storage-classes/)

## AWS

- [Get started with AWS Client VPN](https://docs.aws.amazon.com/vpn/latest/clientvpn-admin/cvpn-getting-started.html)
- [Mutual authentication in AWS Client VPN](https://docs.aws.amazon.com/vpn/latest/clientvpn-admin/client-auth-mutual-enable.html)
- [Client VPN quotas](https://docs.aws.amazon.com/vpn/latest/clientvpn-admin/limits.html)
- [Client VPN resiliency](https://docs.aws.amazon.com/vpn/latest/clientvpn-admin/disaster-recovery-resiliency.html)
- [Associate a target network](https://docs.aws.amazon.com/vpn/latest/clientvpn-admin/cvpn-working-target.html)
- [AWS CLI v2 Linux installation and signature verification](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)
- [Route 53 Public Hosted Zoneの注意事項](https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/hosted-zone-public-considerations.html)
- [Route 53 Hosted Zoneを置き換える場合の注意](https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/domain-replace-hosted-zone.html)
- [EC2 user data](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/user-data.html)
- [Reboot your Amazon EC2 instance](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-instance-reboot.html)
- [Differences between reboot and stop/start](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-instance-lifecycle.html)
- [VPC DHCP option sets](https://docs.aws.amazon.com/vpc/latest/userguide/DHCPOptionSet.html)

## この教材で確認済みの重要要件

- Bootstrap 1台、Control Plane 3台、Computeは少なくとも2台が基本要件。教材ではWorker 3台を使用する。
- 最小リソースはBootstrap/Control Planeが4 CPU・16 GiB RAM・100 GB、Computeが2 CPU・8 GiB RAM・100 GB。
- UPIの`compute.replicas`は`0`とし、Workerを利用者が作成する。
- APIはLayer 4、セッション維持なし。`6443`はAPI、`22623`はMachine Config Server、`80/443`はIngress。
- API、`api-int`、Wildcard Route、各ノードの正引きが必要。APIと各ノードには逆引きも必要。
- AWS Client VPNのクライアントCIDRはVPCや関連routeと重複できず、IPv4では最小`/22`。
- Client VPNではtarget network associationに加えて、routeとauthorization ruleが必要。
- Client VPNの可用性のため、異なるAZの2つ以上のSubnetへassociateする。教材は`infra-a`と`infra-b`を使用する。
- Route 53 Hosted Zoneを削除して再作成すると新しいネームサーバーが割り当てられるため、既存ゾーンを安易に置き換えない。
