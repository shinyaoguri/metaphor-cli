# `contract/` — metaphor ⇄ metaphor-cli の wire スキーマ正典

> **このディレクトリは両リポジトリ（`metaphor` と `metaphor-cli`）に同一内容で置かれます。**
> 片方を変更したら、もう片方の `contract/` も同じ内容に更新してください（`CONTRACT.md` / `scripts/check-contract.sh` と同じ「両リポ identical」運用）。

Probe ファイル契約（[CONTRACT.md](../CONTRACT.md) 契約点 4）の **wire 形式（JSON）を単一スキーマで正典化**したものです。設計判断は [docs/adr/0004-wire-schema-canon-vs-shared-types.md](../docs/adr/0004-wire-schema-canon-vs-shared-types.md)（案D 却下・案C+ 採用）と設計ノート [docs/design/external-coupling-and-contract.md](../docs/design/external-coupling-and-contract.md) を参照。

## なぜ wire スキーマか（型共有ではなく）

`metaphor-cli`（consumer）は Probe 契約型を Swift で decode せず `JSONSerialization` + `[String: Any]` で `request.json` を手組みします。ゆえに契約型を共有 SwiftPM パッケージ化しても（Issue #119 案D）consumer にコンパイル時保証は付きません。**wire schema なら decode 不要で consumer の出力（`request.json`）まで機械検証できる**——これが型共有との決定的な差です。

## ファイル

| スキーマ | 対応 Swift 型（正典） | 生成/消費 |
|---|---|---|
| `frame.schema.json` | `ProbeFrameMetadata` | **producer** (metaphor) が `current/frame.json` を出力 |
| `request.schema.json` | `ProbeRequest` | **consumer** (cli/AI) が `request.json` を出力 |
| `sequence.schema.json` | `ProbeSequenceManifest` | **producer** (metaphor) が `sequence/sequence.json` を出力 |
| `examples/*.json` | — | 正典サンプル payload（下記の二段検証の要） |

JSON Schema draft 2020-12。Swift の実装（`Sources/MetaphorCore/Probe/`）が正典で、スキーマはそれを機械可読に写したもの。

## 二段検証（何が保証され、何が保証されないか）

```
[Swift test]  実 struct → JSONEncoder → in-memory JSON
              ⊨ 構造整合 ⊨  examples/*.json     (examples が実型からドリフトしない番人)
[shell/CI]    examples/*.json  ⊨ schema ⊨  *.schema.json   (check-jsonschema)
              ∴ 推移的に 実エンコーダ出力 ⊨ schema
```

- **producer 側**（metaphor）: `ProbeSchemaConformanceTests` が実型のエンコード結果と `examples/` の構造一致を検証し、`scripts/check-contract-schema.sh` が `examples/` を各スキーマで検証する。
- **consumer 側**（cli）: request.json 生成経路のテストと、同じ `check-contract-schema.sh`。

**保証される**: JSON の構造・キー・値域・enum・`schemaVersion`（`const`）。grep では見られなかった consumer 出力も含む。

**保証されない**（過大評価しない）: 深い意味論——`contentBounds` の「原点左上」、`every` の既定値——は `description` 止まりで強制されません。JSON Schema の破壊的変更検出も未成熟なため、進化ガードは `const: schemaVersion` の可視化に留めます。詳細は設計ノート §5.1。

## 変更手順

1. `Sources/MetaphorCore/Probe/` の型を変える。
2. 対応する `*.schema.json` と `examples/*.json` を更新する。
3. `make contract-schema`（= `scripts/check-contract-schema.sh`）と `swift test` を緑にする。
4. キーのリネーム/削除/型変更なら `schemaVersion` を上げ、`CONTRACT.md` の該当節も更新。
5. **両リポジトリ**の `contract/` と `CONTRACT.md` を同一内容に揃え、もう片方に対応 PR/Issue を立てる。
