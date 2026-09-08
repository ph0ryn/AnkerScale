# 開発と検証

## 開発環境

Apple SiliconとmacOS 14以降を対象に、リポジトリの `flake.nix` を使います。
`flake.lock` がMoonBit overlayとnixpkgsを固定します。
dev shellにはMoonBit、Clang、SQLite、テスト用のPythonが含まれます。

```sh
nix develop
moon version --all
moon check --deny-warn
moon build --deny-warn
moon test --deny-warn
python3 tests/cli_test.py
moon info && moon fmt
```

C FFIを使うため、dev shellとNixビルドは `MOONBIT_NEW_NATIVE=0` を設定します。
根拠は[MoonBitのFFIドキュメント](https://docs.moonbitlang.com/en/latest/language/ffi.html)です。
LLVM実験バックエンドへは切り替えません。
コマンドだけの確認には `moon run cmd/main -- --help` を使えます。
BLEと常駐管理は、用途説明・署名を持つアプリバンドルから実行してください。

## リリースビルドとパッケージ

```sh
nix build
./result/bin/ankerscale --help
nix flake check
```

`nix build` はリリースビルド、MoonBitテスト、CLI統合テストを実行してから
アプリバンドルを作成し、ad-hoc署名を付けて検証します。
SQLiteなどのNix依存はNix storeを参照するため、
生成されたバイナリ単体をNixのないMacへコピーする配布方式ではありません。

開発用バイナリのリリース動作は次でも確認できます。

```sh
nix develop -c moon build --release --deny-warn
nix develop -c moon test --release --deny-warn
nix develop -c env ANKERSCALE_TEST_RELEASE=1 python3 tests/cli_test.py
```

MoonBitを編集した最後には `moon info && moon fmt` を実行し、
生成された `pkg.generated.mbti` の変更が意図どおりか確認します。
Objective-Cには `clang-format` を使用します。

## 自動テストの境界

MoonBitのテストでは次の境界を検証します。

| 境界 | 主な確認 |
| --- | --- |
| パーサー | 53.00 kgの既知パケット、checksum、長さ、status、未知・履歴候補、初期化バイト列 |
| 収集制御 | 購読前のwrite禁止、時間順序、停止、古い接続、別機器、Bluetooth無効、再試行、キャンセル期限 |
| 複数機器 | 共有スキャン、交差したコールバック、機器ごとの試行ID、追加・解除・再登録、障害の隔離、共通の停止期限 |
| GATT照合 | 機器名、サービス、通知・書き込みプロパティを一緒に照合 |

`python3 tests/cli_test.py` は実際のCLI・登録ファイル・SQLiteを一時ディレクトリで検証します。
テスト専用実行ファイルだけがホームディレクトリとBLE・Service Managementの境界を差し替えます。
製品バイナリにはテスト用環境変数による切り替えを設けていません。
登録時の検索・選択・GATT検証・中断・排他・原子的保存・旧形式移行に加え、
複数台の保存、稼働中の追加・解除、全台解除からの復帰、状態表示、設定破損時の停止を検証します。
ネイティブのinclude先が変わったときに古いテストバイナリを使わないよう、
CLIテストは毎回新しいビルドディレクトリを使います。
これらのBLEイベントはテスト入力であり、実際のCoreBluetoothの接続成功を証明しません。
バンドルの署名は `nix build` の中で検証します。

## オフラインでの受信再生

JSONLの1行を一つの受信通知として扱います。次は実測バイト列を使った入力例です。
UUIDと時刻はテスト用です。

```json
{"device":"11111111-1111-1111-1111-111111111111","name":"eufy T9120","session":"connection-1","seq":1,"utc":"2026-09-08T00:00:00.000Z","mono_ms":1000,"service":"FFF0","characteristic":"FFF4","hex":"cfe812b414b3b69f00000f"}
```

```sh
./result/bin/ankerscale replay notifications.jsonl --db /tmp/ankerscale-replay.sqlite3
./result/bin/ankerscale history --db /tmp/ankerscale-replay.sqlite3 --json
```

`mono_ms` は非負の整数で、ファイル内で逆行させません。
`session` と `seq` で接続内の通知を区別します。
replayの成功は実機で受信できた証明ではありません。
入力途中のエラーまでに保存済みの通知は残ります。
この形式は通知の再生用であり、接続制御や権限要求を再生するものではありません。

## 実機で残っている確認

次は実装の存在や自動テストとは分けて、実際のバンドルで確認します。

1. `register` の初回Bluetooth許可、候補の選択、GATT検証と切断後の登録。
2. T9120の起動から検索・接続・購読・初期化・53.00 kgなど実際の表示値の取得まで。
3. 初期化中の受信、重複通知、再接続、同じ体重の別測定が保存結果と一致すること。
4. Bluetooth無効化、許可拒否、接続失敗、停止時に未保存や二重接続を残さないこと。
5. `service start/stop` の登録・承認・解除と、終了時の保存完了。
6. ログイン起動、異常終了後の再起動、スリープ復帰と再接続。
7. バンドル更新時の再登録と権限の引き継ぎ。
8. 待機時のCPU・メモリ・消費電力、接続時間、取得成功率。
9. 2台の同時測定と片方だけの切断、稼働中の登録追加・解除がもう一方の受信を妨げないこと。

スキャンの継続・間欠方式や期限を比較する場合は、
同じ体重計・Mac・条件と試行回数を記録します。
計測していない低消費電力や取得成功率を保証しません。

## 検証記録

2026-09-08に、Nixで固定されたMoonBit 0.1.20260827 / moonc v0.10.11を使用しました。
デバッグ版とリリース版のビルド、MoonBitテスト、
Nixビルド、署名、バンドルの状態参照を確認しています。
Objective-CのClang静的解析も実施しました。

初期実装の確認ではBluetooth権限の要求や実際のサービス登録を行っていません。
既存のCopilotセットアップはUbuntu上のMoonBit導入用のままです。
macOSフレームワークを含むネイティブ検証は、このMacのNix環境で行います。

機器登録・複数台対応の追加では、MoonBitテスト17件とCLI統合テスト33件を用意しています。
CLI統合テストには、キャンセル中の通知保存、保存エラー時の未保存データ報告、
共有トランスポート障害、別プロセスの書き手を過去の収集実行と誤認しない状態表示も含みます。
署名付きバンドルでヘルプ・登録一覧・サービス状態を確認し、3秒の実スキャンも実行しました。
この時点では対応候補が見つからなかったため、実機への登録・測定受信・2台同時接続と
実際のLaunchAgent登録は未確認です。
