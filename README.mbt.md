# AnkerScale

BLE体重計の測定値をMacに保存し、CLIから参照・出力する道具です。
MoonBitが解析・収集制御・保存を担当し、Objective-CがCoreBluetoothと
launchdへの接続を担当します。GUIやクラウド接続はありません。

T9120の既知パケットを対象に実装しています。
検索中の接続・GATT確認・切断と、確認済み候補の表示はT9120一台で確認済みです。
**AnkerScale自体による測定値の実機受信、初回Bluetooth許可、
常駐登録・ログイン起動の確認はまだ完了していません。**
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

まず `register` を開始し、検索中に体重計を起動してください。

```sh
./result/bin/ankerscale register --seconds 20
./result/bin/ankerscale devices
./result/bin/ankerscale collect
```

初回はmacOSでBluetoothの許可が必要です。`register` は機器を検出するとすぐに接続し、
名前・GATT構成・プロパティを確認して切断します。複数台の確認も並行して進めます。
指定時間の検索と開始済みの確認が終わると、登録できる候補を番号付きで表示します。
確認結果を保持するため、体重計がオフになってからPCへ戻っても選択できます。
登録する番号を `1,2` のように入力してください。1台だけでも選択が必要です。
空入力で取り消せます。選択した機器を一括保存し、選択後の再接続は行いません。
確認に失敗した機器は理由を表示し、選択対象から除外します。
登録の確認では通知購読・初期化コマンドの送信・測定値の保存を行いません。

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
./result/bin/ankerscale history --since 2026-09-01
./result/bin/ankerscale history --since 2026-09-01 --json
./result/bin/ankerscale export --format csv > measurements.csv
./result/bin/ankerscale logs
```

`latest` と `history` の通常出力は表形式です。
受信日時（UTC）・体重（kg）・impedance・機器ID・取得元を表示します。
`encrypted_impedance` は表には表示せず、`--json` とCSV／JSONエクスポートに含めます。

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
登録先は `~/Library/LaunchAgents/com.ph0ryn.AnkerScale.collector.plist` です。
macOSが承認を要求した場合は、システム設定のログイン項目で許可してください。
`stop` は保存と切断の完了を待ってから登録を解除します。
ここで解除するのは常駐の登録です。`devices` の機器一覧と測定履歴は残ります。

旧バージョンの `service.json` がある場合、機器一覧はその単一UUIDを読み取ります。
次の登録変更または `service start` で、新しい保存形式へ移行したことを表示します。
`collect` と `service start` の `--device` は廃止しました。

`status` の登録状態、書き手の存在、最後の保存、最後のイベントは別の情報です。
`enabled` だけでは受信が正常だとは判断できません。
`status` の `devices` には、機器ごとの記録された接続状態と直近のエラーも表示します。
通常の表示はテキストです。`service start|stop|status --json` は詳細な状態JSON、
`logs --json` はイベントごとのJSONを返します。
`start` と `stop` は操作結果だけを表示します。状態や履歴の詳細は `status` で確認できます。
`start` は常駐プロセスの初期化完了、`stop` は保存終了と登録解除を確認してから成功を返します。
待機は各段階で最大10秒です。承認が必要な場合や時間内に完了しない場合は、案内付きのエラーを返します。
起動時や保存失敗時の診断は、同じ保存ディレクトリの `collector.log` に追記します。

バンドルを更新するときは、**停止・登録解除してから**新しいバンドルで登録してください。
新しいビルドからも `service stop` を実行できます。登録中はそのNix出力を保持してください。
移動・更新時の権限の引き継ぎは実機確認の対象です。

## 開発資料

- [設計とCLIの契約](docs/design.md)
- [開発と検証](docs/development.md)
- [eufy体重計のBLEプロトコル調査資料](docs/protocol.md)
- [体組成の計算](docs/protocol/bodyComposition.md)（12項目の式、性別・年齢・体格・アスリート設定による分岐）
