# 13. FAQ

## EC2 を 1 台作って SSH で OCP を入れるのですか
いいえ。AWS IPI で installer が必要な cloud 資源と RHCOS node を作ります。

## SNO は本番用 HA cluster と同じですか
いいえ。control plane、etcd、workload が単一障害点です。

## 既存 VPC を使えますか
本教材では扱いません。custom existing VPC は次段階で対象版公式手順を使います。

## EC2 を stop すれば課金は止まりますか
いいえ。EBS、NAT、LB、Public IPv4 等が課金され得ます。

## `kubectl` と `oc` の違いは
`oc` は Kubernetes 操作に加え Route、Project、OpenShift login 等を扱います。

## kubeadmin を使い続けてもよいですか
初期導入用です。IdP と通常の管理者を用意して移行します。

## instance type はどれを選びますか
8 vCPU と必要 memory/storage を満たし、大阪で提供され、対象 OCP が対応する型を API と公式表で確認します。

## installer 実行中に install-config が消えました
仕様です。秘密を含む backup を安全に作り、Git には置きません。

