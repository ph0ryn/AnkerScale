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
./result/bin/ankerscale history --all
./result/bin/ankerscale history --columns weight,body-fat,muscle,water
./result/bin/ankerscale history --since 2026-09-01 --json
./result/bin/ankerscale export --format csv > measurements.csv
./result/bin/ankerscale logs
```

`latest` は受信日時と全12項目を縦に表示します。
`history` は受信日時・体重・BMI・体脂肪率・筋肉量の表です。
`--all` で全12項目、`--columns` で指定した項目を指定順に表示します。日時は常に表示します。
列名は `weight,bmi,body-fat,water,muscle-rate,bone-rate,bmr,visceral-fat,lean,fat,bone,muscle` です。
`body-fat` は体脂肪率、`fat` は脂肪量、`muscle` は筋肉量、`bone` は骨量です。
`--all` と `--columns` は通常表示専用で、併用や `--json` との組み合わせはできません。
機器ID・取得元・impedanceなどの内部値は `latest`・`history` の通常表示から省き、
`--json` とCSV／JSONエクスポートに残します。

日時の表示と履歴検索の日付指定に使うUTCオフセットを設定できます。

```sh
ankerscale config timezone +9  # +09:00に設定
ankerscale config timezone     # 現在の値を表示
ankerscale config timezone +0  # UTCに戻す
```

未設定時は `+00:00` です。`-5` や `+05:30` も指定でき、範囲は `-12:00` から
`+14:00` です。固定時差なので、夏時間への自動切り替えはありません。
設定は `~/Library/Application Support/AnkerScale/config.json` に保存します。
`latest`・`history`・`logs`・`service status`・プロファイルの通常表示に適用し、
`history` / `export` の日付だけの検索条件は設定した時差の午前0時として扱います。
例えば `+9` では `--since 2026-09-09` はUTCの `2026-09-08T15:00:00Z` です。
DB・JSON・CSVの日時と、明示的な `Z` 付き検索条件はUTCを維持します。
収集プロセスのログとプロファイルへの日時入力は引き続きUTCです。

参照コマンドは読み取り専用です。収集が停止していても既存の記録を読めます。
日時・JSON・終了コードの契約は[設計](docs/design.md)に記載しています。

## プロファイル

1人分の生年月日と、性別・身長・通常／アスリート設定を保存できます。
年齢は保存せず、参照日時点の満年齢を生年月日から求めます。
初回は対話形式で設定できます。

```sh
./result/bin/ankerscale profile init
```

生年月日・性別・身長・モード・適用開始日時を順に入力します。
適用開始日時はEnterで現在時刻になり、誤った入力はその項目を入力し直せます。
Ctrl+DまたはCtrl+Cで保存せずに取り消せます。設定済みの場合は `set` / `correct` を使用します。
引数でまとめて設定する場合は次の形です。値は入力例です。

```sh
./result/bin/ankerscale profile set \
  --birth-date 2000-05-20 --sex male --height-cm 170 --mode normal --from 2026-01-01
./result/bin/ankerscale profile
./result/bin/ankerscale profile set --mode athlete
./result/bin/ankerscale profile set --height-cm 171 --from 2026-09-01
./result/bin/ankerscale profile --at 2026-09-01 --json
./result/bin/ankerscale profile history
```

初回は4項目すべてが必要です。性別は `male` / `female`、身長は正の整数のcm、
モードは `normal` / `athlete` を指定します。
`set` は設定の履歴を追加し、省略した項目は適用開始時点の設定を引き継ぎます。
`--from` を省略すると実行時刻から適用します。
初回設定より前の期間を追加する場合は、性別・身長・モードをすべて指定してください。
期間の途中への追加は次の設定が始まるまで有効で、後続の設定は変更しません。

入力ミスは `correct` で訂正します。履歴IDは `profile history` で確認できます。

```sh
./result/bin/ankerscale profile correct 2 --height-cm 170
./result/bin/ankerscale profile correct --birth-date 2000-05-21
```

履歴IDを指定した訂正はその期間だけに、生年月日の訂正は全期間の年齢に反映されます。
生年月日と履歴の項目を同時には訂正できません。
`profile` と `profile history` は `--json`、全プロファイルコマンドは `--db PATH` に対応します。
既定では測定と同じSQLite DBに保存し、収集中でも設定を変更できます。

適用日時・参照日時はUTCです。日付だけの指定はUTCの午前0時を表します。
生年月日は `YYYY-MM-DD` 形式です。2月29日生まれの満年齢は、平年では3月1日に増えます。
設定がない期間の参照は `--json` では `null` を返します。
測定時点で有効なプロファイルを使い、参照時に体組成を計算します。
現行のライブ測定には測定日時がないため、受信日時を基準にします。
計算用の年齢は対象のUTC年から生年を引いた値で、上記の表示用の満年齢とは異なります。
プロフィールを訂正すると該当期間の計算結果も変わります。計算結果はDBへ重複保存しません。
プロフィール未設定なら `Profile is unset.` と案内します。
`latest` は計算できない場合、日時と体重だけを表示し、理由を添えます。
`history` も全件に適用プロフィールがなければ日時と体重の簡易表示にします。
計算できる測定と混在する場合は列を維持し、欠損値を `—` と表示します。
明示した `--all`・`--columns` は簡易表示より優先します。
JSON／CSVには全計算値と `profile_id`、`composition_age`、`composition_method`、
`composition_error` を含めます。計算できない値はJSONでは `null`、CSVでは空欄です。
計算式と丸め方は[体組成の計算](docs/protocol/bodyComposition.md)を参照してください。

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
