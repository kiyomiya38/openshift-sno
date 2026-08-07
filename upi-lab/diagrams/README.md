# アーキテクチャ図

このディレクトリには、配布資料で使用するアーキテクチャ図のMermaid原本と、同じ原本から生成したSVG・PNGを保存します。構成値の正本はTerraform、Ansible、[構成とパラメーター](../docs/01-architecture-and-parameters.md)です。構成を変更した場合は、コード、表、図、検証条件を同じ変更として更新します。

| 図 | 目的 | Mermaid原本 | 配布用 |
|---|---|---|---|
| 全体アーキテクチャ | 管理経路、OpenShift入口、基盤サービス、外部接続、単一障害点 | [01-architecture-overview.mmd](01-architecture-overview.mmd) | [SVG](01-architecture-overview.svg) / [PNG](01-architecture-overview.png) |
| ネットワーク・AZ配置 | 3 AZ、9 Subnet、固定IP、Client VPN association、NAT配置 | [02-network-az-layout.mmd](02-network-az-layout.mmd) | [SVG](02-network-az-layout.svg) / [PNG](02-network-az-layout.png) |
| 通信フロー | 管理、DNS/NTP、API/MCS/Ingress、Ignition、外部通信、NFS | [03-communication-flows.mmd](03-communication-flows.mmd) | [SVG](03-communication-flows.svg) / [PNG](03-communication-flows.png) |

## 凡例

- 青: AWSマネージドサービスまたは論理サービス。
- 緑: RHEL基盤サービス。
- 橙: OpenShiftノードまたはワークロード。
- 黄の破線: 構築時だけ存在または使用する要素。
- 赤の太枠: 意図的に残している単一障害点。
- 灰色の破線: 参照関係、未統合、許可されている代替経路など、通常の主経路ではない関係。

色だけに依存せず、枠線、破線、ラベルでも意味を区別しています。SVGをMarkdownの標準表示に使い、SVGを表示できない環境や画像貼付にはPNGを使用します。図だけで運用判断せず、同じ内容を文章と表でも確認してください。

## 再生成

検証済みのMermaid CLIは`11.16.0`です。Node.jsとnpmを準備し、固定版を明示してインストールします。

```bash
npm install --global @mermaid-js/mermaid-cli@11.16.0
mmdc --version
```

リポジトリ直下の`upi-lab`で次を実行します。

```bash
bash scripts/93-render-diagrams.sh
bash scripts/90-static-validation.sh
```

スクリプトは3個の`.mmd`から同名の`.svg`と`.png`を上書き生成します。SVG・PNGを直接編集しません。生成後は3画像を100%表示で開き、文字切れ、矢印の方向、重なり、IP・ポートを目視確認します。

Mermaid CLIはnpmからコードとブラウザー依存物を取得します。信頼できるネットワークで固定versionを使用し、リリース時は[検証version一覧](../configs/tested-versions.yaml)と同時に更新してください。
