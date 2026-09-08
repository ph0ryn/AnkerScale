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

体重計を起動し、収集する機器を登録します。

```sh
./result/bin/ankerscale register --seconds 20
./result/bin/ankerscale devices
./result/bin/ankerscale collect
```

初回はmacOSでBluetoothの許可が必要です。`register` は指定時間の検索後、
対応候補を番号付きで表示します。登録する番号を `1,2` のように入力してください。
1台だけでも選択が必要です。空入力で取り消せます。
接続して名前・GATT構成・プロパティを確認し、全選択機器の検証と切断が成功したら登録します。
この確認では初期化コマンドを送信せず、検証に失敗した場合は登録を変更しません。

`devices` は登録済み一覧を表示し、Bluetoothへのアクセスは不要です。
`devices --json` では一覧をJSON配列で取得できます。
`collect` は登録した全機器から同時に収集し、機器の識別子と測定値を表示します。
まず前面で受信を確認し、`Ctrl+C` で停止してください。

登録情報は `~/Library/Application Support/AnkerScale/devices.json` に保存します。
収集対象を追加するときは `register`、外すときは `unregister` で選択します。
稼働中の収集にも約1秒で反映され、対象から外しても測定履歴は残ります。
全台を解除すると、収集プロセスは新しい登録を待ちます。

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
./result/bin/ankerscale service start
./result/bin/ankerscale service status
./result/bin/ankerscale service stop
```

`start` はユーザーのLaunchAgentを登録し、ログイン後の起動も有効にします。
macOSが承認を要求した場合は、システム設定のログイン項目で許可してください。
`stop` は保存と切断の完了を待ってから登録を解除します。
ここで解除するのは常駐の登録です。`devices` の機器一覧と測定履歴は残ります。

旧バージョンの `service.json` がある場合、機器一覧はその単一UUIDを読み取ります。
次の登録変更または `service start` で、新しい保存形式へ移行したことを表示します。
`collect` と `service start` の `--device` は廃止しました。

`status` の登録状態、書き手の存在、最後の保存、最後のイベントは別の情報です。
`enabled` だけでは受信が正常だとは判断できません。
`status` の `devices` には、機器ごとの記録された接続状態と直近のエラーも表示します。
起動時や保存失敗時の診断は、同じ保存ディレクトリの `collector.log` に追記します。

バンドルを更新するときは、**古いバンドルから停止・登録解除してから**
新しいバンドルで登録してください。登録中はそのNix出力を保持してください。
移動・更新時の権限の引き継ぎは実機確認の対象です。

## 開発資料

- [設計とCLIの契約](docs/design.md)
- [開発と検証](docs/development.md)
- [機種別の通信観測記録](docs/protocol.md)
