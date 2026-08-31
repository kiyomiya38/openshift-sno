# 00. 設計方針

## この章の目的

本教材で再現するもの、AWS固有の代替、意図的に残す単一障害点を理解します。

## 採用する方式

### クラスターの公開範囲

API、Machine Config Server、IngressはInternal NLBを入口とし、インターネットへ直接公開しません。管理端末はAWS Client VPNへ接続して利用します。EC2にはPublic IPv4を割り当てません。

`22623/tcp` はクラスター内部からだけ到達可能にします。`6443/tcp`、`80/tcp`、`443/tcp` はClient VPNとクラスター内部から到達可能にします。

### DNS

EC2上のBIND 2台を、クラスター用正引きゾーンと逆引きゾーンの権威DNS兼キャッシュDNSにします。Client VPNは構築直後だけVPC Resolver `10.80.0.2`を使用し、BIND完成後にこの2台へ切り替えます。

Route 53の既存Public Hosted ZoneはTerraformのdata sourceで読み取り参照し、resourceやstateへ取り込みません。内部NLBの名前やプライベートIPをPublic DNSへ公開しません。必要な公開用レコードは、disconnected演習とは別の機能演習で追加します。

### ロードバランサー

Internal NLBを固定入口とし、その後段にHAProxy 2台を配置します。

```text
Client VPN / OpenShift Nodes
            |
      Internal NLB
       /          \
  HAProxy-0    HAProxy-1
       \          /
   Bootstrap / Control Plane / Worker
```

NLBはAWS上でL2仮想IPを代替するための部品です。HAProxyで、UPIに必要なバックエンド追加、Bootstrap切り離し、ヘルスチェックを学びます。

### Ignition配布

Installerの内部Apacheを一時的なIgnition配布元にします。完全なIgnitionはリポジトリとTerraform stateへ保存せず、EC2 user dataには内部URL、SHA-512、ノードFQDNだけを含む小さいwrapperを渡します。通信元はCluster Node用Security GroupとApacheの送信元制限で限定します。

HTTPは機密性を提供しないため、SHA-512は改ざん検知に使用します。初回構築完了後はApacheを停止し、配信中のクラスタ固有資材を削除します。本番設計ではHTTPSと専用CAも検討します。

### 外部接続

初期構築では1台のNAT Gatewayを使用し、install-configのHTTP/HTTPS ProxyとしてSquidを指定します。Security Group egressとNAT routeは直接外向き通信も許すため、ネットワークレベルでProxy経由を強制する設計ではありません。1台のNAT Gatewayは単一障害点です。

最初から完全disconnectedにはしません。このリポジトリはinstall-configへのProxy設定と、将来のミラー先となるRegistryの準備までを対象にします。リリースイメージ、Operator Catalog、追加の信頼CA、ImageContentSourcePolicy/ImageDigestMirrorSetなどを使うdisconnected化手順は未実装で、構築完了条件にも含めません。

### ストレージ

NFS 1台とNFS Subdir External Provisionerを学習用StorageClassとして使用します。NFSサーバーは単一障害点であり、本番ストレージ設計の代替ではありません。

## サポート境界

この環境はAWS EC2上でbare-metal UPIの手順を模擬します。正式なAWS IPI/UPI構成ではなく、Red Hatが試験済みとするAWSインストール方式と同一ではありません。AWS Cloud Controller Managerや自動ロードバランサー作成には依存しません。

初期設計には次の意図的な単一障害点があります。

- NAT Gateway、Proxy/Registry、NFSは各1台。
- AWS Client VPNは`infra-a`と`infra-b`の2 AZへassociateするが、クラスター全体の冗長性を保証しない。
- Terraform stateはローカルで、複数人の同時操作や遠隔backendを前提にしない。

HAProxy 2台とOpenShift Nodeの3 AZ配置は検証しますが、環境全体を高可用または本番相当とは呼びません。

## 完了条件

- 内部公開、DNS、NLB、HAProxy、Proxyの責任分界を説明できる。
- 初期構成の単一障害点がNAT Gateway、Proxy、Registry、NFSであることを説明できる。
- この環境を正式なAWS本番構成と呼ばない理由を説明できる。

すべて満たしたら[01. 構成とパラメーター](01-architecture-and-parameters.md)へ進みます。
