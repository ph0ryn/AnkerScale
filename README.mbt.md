# AnkerScale

BLE体重計の測定値をMacに保存し、CLIから参照・出力する道具です。
MoonBitが解析・収集制御・保存を担当し、Objective-CがCoreBluetoothと
Service Managementへの接続を担当します。GUIやクラウド接続はありません。

T9120の既知パケットを対象に実装しています。**AnkerScale自体による実機受信、
Bluetooth権限、常駐登録・ログイン起動の確認はまだ完了していません。**
他機種や履歴パケットを対応済みとは扱いません。
確認済みの範囲は[開発と検証](docs/development.md)を参照してください。

## ビルドと起動

Apple Silicon、macOS 14以降、Nixを使用します。

```sh
nix build
./result/bin/ankerscale --help
```

ビルド時にMoonBitのリリース版テストを実行します。
生成物は `result/Applications/AnkerScale.app` とCLIの入口です。
バンドルにはローカル利用向けのad-hoc署名を付けます。
Developer ID署名・公証による配布物ではありません。

## 測定を記録する

まず前面で受信を確認します。体重計を起動してから検索してください。

```sh
./result/bin/ankerscale devices --seconds 20
./result/bin/ankerscale collect --device <表示された体重計のUUID>
```

初回はmacOSでBluetoothの許可が必要です。`devices` は周辺機器をJSONLで表示します。
UUIDを明示して選択し、接続後に名前・GATT構成・プロパティを確認します。
未確認の機器へT9120の初期化コマンドを送信しません。
収集は `Ctrl+C` で停止できます。

既定の保存先は
`~/Library/Application Support/AnkerScale/records.sqlite3` です。
rawと測定値は同じトランザクションで保存し、重複・未知・不正な通知もrawに残します。

```sh
./result/bin/ankerscale latest
./result/bin/ankerscale history --since 2026-09-01 --json
./result/bin/ankerscale export --format csv > measurements.csv
./result/bin/ankerscale logs
```

参照コマンドは読み取り専用です。収集が停止していても既存の記録を読めます。
日時・JSON・終了コードの契約は[設計](docs/design.md)に記載しています。

## 常駐管理

前面での受信確認後に、同じバンドルから登録します。

```sh
./result/bin/ankerscale service start --device <体重計のUUID>
./result/bin/ankerscale service status
./result/bin/ankerscale service stop
```

`start` はユーザーのLaunchAgentを登録し、ログイン後の起動も有効にします。
macOSが承認を要求した場合は、システム設定のログイン項目で許可してください。
`stop` は保存と切断の完了を待ってから登録を解除します。

`status` の登録状態、書き手の存在、最後の保存、最後のイベントは別の情報です。
`enabled` だけでは受信が正常だとは判断できません。
起動時や保存失敗時の診断は、同じ保存ディレクトリの `collector.log` に追記します。

バンドルを更新するときは、**古いバンドルから停止・登録解除してから**
新しいバンドルで登録してください。登録中はそのNix出力を保持してください。
移動・更新時の権限の引き継ぎは実機確認の対象です。

## 開発資料

- [設計とCLIの契約](docs/design.md)
- [開発と検証](docs/development.md)
- [機種別の通信観測記録](docs/protocol.md)
