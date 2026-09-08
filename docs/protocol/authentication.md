# T9148 / T9150系 BLE認証・暗号化プロトコル

[全体索引・確認状況](../protocol.md)

この資料は、T9148/T9149系およびT9150/T9130系で確認できる認証と、認証後の
分割フレームを通信仕様としてまとめたものです。以下の「確認済み」はアプリが
送受信する形式から復元できることを指し、すべてのファームウェアとの相互接続を
保証しません。実機で確認していない値は、検算用の固定例と区別しています。

## 全体像

通常の認証は、次の4段階です。

```text
アプリ                         体重計
  |--- C0: randomUuid暗号化 --->|
  |<-- C1: deviceUuid暗号化 ----|
  |--- C2: randomUuid_deviceUuid
  |        暗号化 ------------->|
  |<-- C3: 認証成功マーカー -----|
```

`C0`、`C1`、`C2`、`C3`のコマンド名は、フレーム先頭の1 byteです。`C0`〜`C2`の
AES結果はBase64（改行なし）に変換し、BLE上ではBase64 ASCII bytesを最大15 byte
ずつ送ります。本資料で連続したhex文字列として示す値は、そのwire byteの表記または
分割前の内部表現です。hex文字のASCII bytesをさらに送るわけではありません。

認証後のT9148系コマンドは`C6`フレームで送受信します。`C6`はAES暗号文ではなく、
コマンドのbyte列を小分けにする搬送フレームです。

## 鍵の作り方

認証鍵は、Bluetooth MACアドレスの文字列から作ります。

1. MACアドレスの`:`をすべて削除する。
2. ASCII文字列として大文字にする。
3. そのUTF-8バイト列にMD5を適用する。
4. 32桁のMD5 hexを2桁ずつdecodeし、16 byteのAES-128鍵にする。

式で書くと次のとおりです。

```text
normalized = UPPERCASE(mac.replace(":", ""))
secretKeyHex = MD5_UTF8_HEX(normalized).lowercase()
secretKey = HEX_DECODE(secretKeyHex)       # 16 bytes
```

MD5の表示は大文字でも小文字でも、最後にhex decodeする限り同じ鍵です。MACに
ハイフンを使う形式、空白を含む形式、MACのbyte順を反転した形式はこの仕様には
ありません。

認証中に使うMACは、接続先を指定したときのMACです。MACが得られない場合に別の
文字列を代用する仕様はありません。

## randomUuid

`randomUuid`はUUID全体をそのまま使わず、UUID文字列表現を小文字化した先頭15文字
です。UUIDの区切りハイフンも文字数に含まれます。

```text
UUID文字列:  01234567-89ab-4cde-8f01-23456789abcd
randomUuid:  01234567-89ab-4
```

UUID生成の乱数値は接続ごとに変わるため、固定例では上のようなUUID文字列を入力に
使います。C4の追加UUIDも同じ15文字形式です。

## AESの変換

暗号化は次の順序です。

```text
plaintext UTF-8 bytes
  -> AES-128-CBC / PKCS7 padding
  -> Base64 (改行なし)
  -> Base64 ASCII bytesをhex文字列に変換
```

復号は逆順です。

```text
wire payload bytes（以下のhex表記）
  -> そのままBase64 ASCII bytesとして扱う
  -> Base64 decodeするとAES ciphertext
  -> AES-128-CBC / PKCS7 paddingを復号
  -> UTF-8文字列
```

IVは文字列`0000000000000000`をUTF-8でbyte化したものです。つまり、IVの16 byteは
すべて`0x30`であり、16個の`0x00`ではありません。

```text
IV文字列:  0000000000000000
IV bytes:  30 30 30 30 30 30 30 30 30 30 30 30 30 30 30 30
```

AESの鍵はMD5のhex文字列をASCIIのまま使わず、必ずhex decodeした16 byteを使います。
Base64は改行を付けず、paddingの`=`を保持します。最後のhex化は文字列の文字を
byte値へ変換する操作であり、Base64を再度decodeしたciphertextをhex化する操作では
ありません。

## 認証フレーム

### C0 / C2 / C4の共通形式

アプリから送る認証フレームは、次のbyte列です。

```text
offset  size  内容
0       1     コマンド (C0 / C2 / C4)
1       1     総フレーム数 total
2       1     フレーム番号 index (0始まり)
3       1     データ総byte数 length
4       n     データ payload
4+n     1     XOR checksum
```

`payload`はAES結果そのものではありません。AES結果をBase64化し、そのBase64 ASCII
bytesをhex文字列で表した内部表現を30 hex文字ずつ切ります。フレームを組み立てる
ときにhex decodeするため、wire上のpayloadはBase64 ASCII bytesです。例えばBase64の
`3Bmf...`はwire上で`33 42 6d 66 ...`になります。1フレームに入るwire payloadは
最大15 byteです。

```text
encryptedHex = AesResultBase64Asciiをhex化した文字列
total = ceil(encryptedHex.length / 30)
payload_i = encryptedHex.substring(i * 30, min(encryptedHex.length, (i + 1) * 30))
length = encryptedHex.length / 2
```

headerとpayloadをhex decodeしたbyte列全体に対してXORを取り、最後に1 byte追加します。
checksum自身はXORに含めません。`total`、`index`、`length`は1 byteのhex表記です。

`C0`はrandomUuid、`C2`は`randomUuid_deviceUuid`を暗号化した結果をpayloadにします。
`C4`も同じ分割形式ですが、暗号化するUUIDと鍵の扱いが異なります（後述）。

### C1の受信形式

体重計から返る`C1`も、確認した再構成処理ではC0/C2と同じheader幅を使います。

```text
offset  size  内容
0       1     C1
1       1     総フレーム数 total
2       1     フレーム番号 index
3       1     length欄（総byte数と推定、受信処理では未参照）
4       n     暗号化データの断片
4+n     1     XOR checksum
```

受信側は`index == 0`で蓄積をリセットし、それ以外ではpayloadを後ろへ連結します。
`index == total - 1`になった時点で連結したhex文字列をAES復号し、
`deviceUuid`を得ます。その後、次の文字列を作ります。

```text
composeUuid = randomUuid + "_" + deviceUuid
```

`composeUuid`をMAC由来の`secretKey`でAES変換し、C2として送信します。

### C3の成功応答

通常の認証完了は、受信データ中に次の5 byteが現れることで判定されます。

```text
c3 01 00 01 00
```

実装上は、C3のhex文字列に`C301000100`が含まれているかを見て成功通知を発行
します。C3に対してAES復号は行いません。成功通知の後で通常データを受け取れる
ことを実機で確認する必要があります。

### C4 / C5の追加認証経路

C0〜C3の後に使える追加経路も定義されています。

1. 新しい15文字UUIDを生成する。
2. `appNewKey = MD5_UTF8_HEX(newUuid)`を作る。
3. `newUuid`を`secretKey`でAES変換する。
4. 結果をC4で送る。
5. 体重計からC5を受け取る。
6. C5のpayloadを`appNewKey`でAES復号する。
7. 復号結果が`randomUuid_deviceUuid`と大小文字を区別せず一致すれば追加認証成功とする。

C4はC0/C2と同じ30 hex文字単位の分割形式です。C5の再構成もC1と同じく
`index == 0`でリセットし、最終indexで復号します。

この追加経路は、通常のT9148/T9150接続シーケンスで必ず送られることを確認できて
いません。実機でC4/C5の送受信を観測するまでは、C0→C1→C2→C3だけを通常経路と
扱います。

## C6データフレーム

T9148/T9149系の認証後コマンドと応答には、次のC6分割フレームを使います。

```text
offset  size  内容
0       1     C6
1       1     総フレーム数 total
2       1     フレーム番号 index (0始まり)
3       1     コマンドpayloadの総byte数 length（全fragment共通）
4       n     コマンドpayload
4+n     1     XOR checksum
```

payloadは元コマンドをhex文字列にしたものを30 hex文字ずつ切り、hex decodeして
wire byteへ戻します。従って1フレームのpayloadは最大15 byteです。headerの`length`
は各fragmentの長さではなく、全fragmentを合わせたpayloadのbyte数です。

```text
total = ceil(commandHex.length / 30)
length = commandHex.length / 2
payload_i = commandHex.substring(i * 30, min(commandHex.length, (i + 1) * 30))
frame_i = C6 total index length payload_i checksum
```

受信側はC6のpayloadを連結し、最終フレームで連結済みのコマンドhex文字列を返します。
この処理はC6 payloadのAES復号を行わず、XOR checksumも検証しません。送信側では
checksumを付けるため、実装する場合は送受信の検証方針を分けてください。

T9148の設定・大容量データには、C6の内側に入るinner frameもあります。inner frameを
作った後、そのinner frame全体をhex化してC6で再分割して送ります。最終wireはC6の
outer frameです。

```text
head | frameLength | total | index | originalLength(LE16) | payload | XOR
```

inner frameのpayloadは最大106 hex文字（53 byte）です。`frameLength`は
`payload byte数 + 5`、inner frame全体のbyte数は`payload byte数 + 7`です。
`originalLength`は元データ全体のbyte数をLE16で表します。inner frameのXORを付けた
後、inner frame全体をC6のpayloadとして最大15 byteずつ分割し、C6側のXORも付けます。
例えばinner payloadが53 byteならinner frameは60 byte（`payload + 7`）となり、
outer C6はその60 byteを4 fragmentに分けます。これは認証C0/C2/C4の形式ではありません。

## 機種別のGATTと認証シーケンス

UUIDは[ルート資料のUUID表記](../protocol.md#通信ファミリーとgatt早見表)に従います。
以下の`FFF0`のような16-bit表記は、Bluetooth Base UUID
`0000xxxx-0000-1000-8000-00805f9b34fb`を補った値です。

| 系統 | service | 主な通知 | 主なwrite | 追加チャネル | MTU要求 |
| --- | --- | --- | --- | --- | --- |
| T9120/T9146/T9147 | FFF0 | FFF4 | FFF1 | なし | なし |
| T9148/T9149 | FFF0 | FFF4、FFF2 | FFF1 | Device Information、Battery | なし |
| T9150/T9130 | FFF0 | FFF1、FFF3、FFF2 | FFF2 | 制御write FFF1、Device Information、Battery | 244を要求 |

### T9148 / T9149

1. FFF0 serviceを探索する。
2. FFF4のCCCDを書き込み、通知を有効にする。
3. FFF4のdescriptor write成功後、FFF2のCCCDを書き込む。
4. FFF2のdescriptor write成功後、C0をFFF1へ送る。
5. C1を受け取ったら、C2をFFF1へ送る。
6. C3の成功マーカーを確認する。
7. 認証後のC6コマンドはFFF1へ書き込む。

FFF4とFFF2の両方を通知購読します。認証dispatcherは通知characteristic UUIDで
C1/C3/C6を限定せずにフレーム先頭を見て処理するため、C1/C3/C6がどちらの通知
characteristicから届くかはこの資料では確定しません。実機では購読した通知ごとに
UUIDとbyte列を記録して確認してください。FFF2はreal-data通知にも使われます。

### T9150 / T9130

1. FFF0 serviceを探索する。
2. FFF1のCCCDを書き込む。
3. FFF1のdescriptor write成功後、FFF3のCCCDを書き込む。
4. FFF3のdescriptor write成功後、FFF2のCCCDを書き込む。
5. FFF2のdescriptor write成功後、C0をFFF2へ送る。
6. C1/C3はFFF2で受信し、C2はFFF2へ送信する。
7. FFF3はreal-data通知、FFF1は制御writeに使われます。

T9150系は接続後にATT MTU 244を要求します。要求値は実際に確立したMTUを保証
しないため、書き込みサイズはネゴシエーション結果に従ってください。認証フレーム
自体は30 hex文字（15 byte）単位で分割するため、MTU拡張の有無で認証フレームの
論理形式を変更しません。

### T9120 / T9146 / T9147

この系統はFFF0/FFF4/FFF1を使いますが、ここで定義したMAC由来AES認証は通常の
測定開始経路に含まれません。T9148/T9150のC0を送信せず、機種固有の測定フレームを
使います。

### CCCDの値

通知を有効にする場合はCCCD（通常は`0x2902`）へ`01 00`、indicationの場合は
`02 00`を書きます。通知characteristicのdescriptor write完了を待ってから、次の
チャネルを有効にしてください。確認できた購読順序は、T9148/T9149がFFF4→FFF2、
T9150/T9130がFFF1→FFF3→FFF2です。別順序での互換性は確認していません。

## macOS互換性注記

この認証方式には体重計のBluetooth MACアドレスが必要です。macOSのCoreBluetoothが
渡すpeer UUIDはMACアドレスではなく、鍵入力の代用にはできません。macOSでMACを
取得できる経路は、現時点では未確認です。

## 固定入力による検算例

以下は暗号処理と分割処理の固定例です。これは実機から取得した乱数ではなく、実装を
比較するための公開入力です。

### AESとC0

入力を次のように固定します。

```text
MAC             02:00:00:00:00:01
normalized MAC  020000000001
secretKey       65b51c8d827802f3677a8fd881f41edb
UUID文字列      01234567-89ab-4cde-8f01-23456789abcd
randomUuid      01234567-89ab-4
IV              30303030303030303030303030303030
```

AES結果は次のとおりです。

```text
Base64          KSQ9eJGTWrBW+kk9BG03zw==
encryptedHex    4b535139654a4754577242572b6b6b39424730337a773d3d
```

`encryptedHex`を30 hex文字ずつ分割し、XORを追加したC0 wire frameは次の2個です。

```text
c0 02 00 18 4b 53 51 39 65 4a 47 54 57 72 42 57 2b 6b 6b 8d
c0 02 01 18 39 42 47 30 33 7a 77 3d 3d e9
```

最初のフレームのXORは`8d`、2個目のXORは`e9`です。最初の`c0`、`02`、`00`、
`18`は、それぞれコマンド、総数、index、暗号化hexデータの総byte数です。

シェルとOpenSSLで鍵とAES結果を再計算する例です。

```sh
printf %s 020000000001 | openssl dgst -md5
# 65b51c8d827802f3677a8fd881f41edb
printf %s '01234567-89ab-4' \
  | openssl enc -aes-128-cbc -K 65b51c8d827802f3677a8fd881f41edb \
      -iv 30303030303030303030303030303030 -a -A
# KSQ9eJGTWrBW+kk9BG03zw==
```

### C6

T9148の単位設定payload（unit=0）を固定入力にします。

```text
command payload  fd 0a 00 00 00 00 00 00 00 00 00 f7
C6 frame         c6 01 00 0c fd 0a 00 00 00 00 00 00 00 00 00 f7 cb
```

payloadは12 byteなので、C6 headerのlengthは`0c`です。headerとpayloadのXORは
`cb`です。C6はこのpayloadをAES変換せず、そのまま搬送します。

複数fragmentでは、全fragmentのlengthが同じであることを確認できます。次の16 byte
payloadは機能名を持たない搬送形式の固定例です。

```text
payload        00 11 22 33 44 55 66 77 88 99 aa bb cc dd ee ff
fragment 0     c6 02 00 10 00 11 22 33 44 55 66 77 88 99 aa bb cc dd ee 2b
fragment 1     c6 02 01 10 ff 2a
```

両fragmentのlengthは総payload長16 byteの`10`であり、fragment 1だけの長さ`01`
ではありません。各fragment末尾のXORはそれぞれ`2b`、`2a`です。

## 未確認事項と失敗条件

- C3の成功マーカー以外に、共通して使われる認証失敗wire packetは確認できていません。
- C1/C5/C6の受信処理は、少なくとも通常経路ではXORやlengthの不一致を明示的に
  失敗通知へ変換しません。実装側で検証する場合は、受信データを捨てる条件を別に
  定義してください。
- C1/C5/C6はindexを見て最終フレームを判断しますが、欠落・重複・順序逆転を
  回復する仕様は確認できていません。送受信はindex順に1回ずつ行います。
- T9148/T9150の暗号認証はT9120/T9146/T9147のFFF1/FFF4測定フレームへ適用できません。
- C4/C5は実機で到達と成功応答を確認するまで、必須手順にしません。
- MACが取得できないmacOSでは、暗号を変更するより先にMACの観測経路を特定します。
