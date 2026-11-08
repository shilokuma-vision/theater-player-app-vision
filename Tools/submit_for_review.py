#!/usr/bin/env python3
"""App Store のバージョンに処理済みのビルドを付け、審査に出す（審査に出すのは --submit を付けたときだけ）。

    python3 Tools/submit_for_review.py --app-version 1.0.0 --dry-run              # 付けるビルドと、提出の予定だけ出す
    python3 Tools/submit_for_review.py --app-version 1.0.0                        # ビルドを付ける（審査には出さない）
    python3 Tools/submit_for_review.py --app-version 1.0.0 --build 42 --submit    # ビルド 42 を付けて、審査に出す

ビルドは、そのバージョン（CFBundleShortVersionString が同じ）の、処理が終わって（VALID）期限の切れていないものから選ぶ。
--build（ビルド番号。CFBundleVersion）を省くと、いちばん新しくアップロードしたものを使う。
develop へのマージでも同じバージョンのビルドが上がるので、リリースのブランチのビルドを付けるときは --build で選ぶ。

審査への提出は reviewSubmissions で行う（提出の下書きを作り、バージョンを入れて、提出する）。
バージョンの必須の属性（visionOS の hasHighMotionLabel など。AppStore/app_info.json から Metadata/App Store が書く）が
未設定だと提出が 409 で止まるので、審査に出すときは、何かを書き込む前に確かめて止める（dry-run でも止める）。
提出の下書き（READY_FOR_REVIEW）が残っていれば、それを使う。審査中・問題のある提出があるときは止める。
提出の前に、Metadata/App Store の反映と、App Store Connect の画面での入力（App のプライバシーなど）を済ませておく。

触るのは **編集できる状態のバージョンだけ**。--dry-run では何も書き込まない。

認証は App Store Connect API Key（.p8）。次の環境変数でも渡せる。

    APP_STORE_CONNECT_KEY_ID / APP_STORE_CONNECT_ISSUER_ID / APP_STORE_CONNECT_PRIVATE_KEY_PATH

PyJWT が要る: `python3 -m pip install pyjwt cryptography`
"""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from app_store_config import bundle_id
from upload_app_info import VERSION_ATTRIBUTES

#: 審査に出したあとの提出の状態。これがあるあいだは新しく出さない
ACTIVE_SUBMISSION_STATES = ("WAITING_FOR_REVIEW", "IN_REVIEW", "UNRESOLVED_ISSUES", "CANCELING", "COMPLETING")

#: 提出の下書き（まだ審査に出していない提出）の状態
DRAFT_SUBMISSION_STATE = "READY_FOR_REVIEW"

#: バージョンのリリースの方法（審査を通ったあとの配信のしかた）
RELEASE_TYPES = {
    "MANUAL": "審査を通ったら、App Store Connect で手動で配信する",
    "AFTER_APPROVAL": "審査を通ったら、すぐに自動で配信する",
    "SCHEDULED": "審査を通ったら、指定した日時に配信する",
}


def build_label(build: dict | None) -> str:
    if build is None:
        return "（なし）"
    attributes = build.get("attributes") or {}
    return f"ビルド {attributes.get('version', '?')}（{attributes.get('uploadedDate', '?')} にアップロード）"


def find_build(client, app_id: str, version_string: str, platform: str, build_number: str | None) -> dict:
    """そのバージョンの、処理の終わった期限内のビルド。ビルド番号を省くと、いちばん新しくアップロードしたもの。"""
    params = {
        "filter[app]": app_id,
        "filter[preReleaseVersion.version]": version_string,
        "filter[preReleaseVersion.platform]": platform,
        "sort": "-uploadedDate",
    }
    if build_number:
        params["filter[version]"] = build_number
    builds = client.get_all("/v1/builds", params)
    valid = [
        build for build in builds
        if build["attributes"].get("processingState") == "VALID" and not build["attributes"].get("expired")
    ]
    if valid:
        return valid[0]

    target = f"ビルド {build_number} " if build_number else "ビルド"
    if builds:
        states = ", ".join(
            f"{build['attributes'].get('version')}: {build['attributes'].get('processingState')}"
            + ("（期限切れ）" if build["attributes"].get("expired") else "")
            for build in builds[:5]
        )
        raise SystemExit(
            f"バージョン {version_string} の{target}は、まだ使えません（{states}）。"
            "処理（PROCESSING）が終わるのを待つか、別のビルドを選んでください。"
        )
    raise SystemExit(
        f"バージョン {version_string} の{target}が App Store Connect にありません。"
        "Upload のワークフローでアップロードしてから実行してください。"
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--bundle-id", help="省略すると Configs/Project.xcconfig から読む")
    parser.add_argument("--app-version", help="ビルドを付けるバージョン。省略すると編集できるバージョンを自動で選ぶ")
    parser.add_argument("--build", help="付けるビルドのビルド番号（CFBundleVersion）。省略すると最新の処理済みのビルド")
    parser.add_argument("--submit", action="store_true", help="ビルドを付けたあと、審査に出す")
    parser.add_argument("--key-id", default=os.environ.get("APP_STORE_CONNECT_KEY_ID"))
    parser.add_argument("--issuer-id", default=os.environ.get("APP_STORE_CONNECT_ISSUER_ID"))
    parser.add_argument(
        "--private-key",
        type=Path,
        default=os.environ.get("APP_STORE_CONNECT_PRIVATE_KEY_PATH"),
        help="App Store Connect API Key の .p8",
    )
    parser.add_argument("--dry-run", action="store_true", help="何も書き換えず、付けるビルドと提出の予定だけ出す")
    args = parser.parse_args()

    missing_key = [
        name for name, value in
        [("--key-id", args.key_id), ("--issuer-id", args.issuer_id), ("--private-key", args.private_key)]
        if not value
    ]
    if missing_key:
        raise SystemExit(f"認証情報が足りません: {', '.join(missing_key)}")

    from app_store_connect import PLATFORM, AppStoreConnect

    client = AppStoreConnect(
        args.key_id, args.issuer_id, Path(args.private_key).read_text(), dry_run=args.dry_run
    )

    def write(method: str, path: str, payload: dict | None = None) -> dict:
        # dry-run では何も書き込まない（提出は取り消しに手間がかかるので、書き込みはすべてここを通す）
        if args.dry_run:
            return {}
        return client.post(path, payload) if method == "POST" else client.patch(path, payload)

    app = client.find_app(args.bundle_id or bundle_id())
    version = client.find_version(app["id"], args.app_version)
    version_string = version["attributes"]["versionString"]
    print(f"対象: {app['attributes']['name']} {version_string} ({version['attributes']['appStoreState']})")
    if args.dry_run:
        print("--dry-run: App Store Connect には何も書き込みません")

    # 審査の提出の状態。審査に出すなら、審査中・対応の要る提出があるときは、何も書き込まずに止める
    submissions = client.get_all(
        "/v1/reviewSubmissions",
        {
            "filter[app]": app["id"],
            "filter[platform]": PLATFORM,
            "filter[state]": ",".join((DRAFT_SUBMISSION_STATE, *ACTIVE_SUBMISSION_STATES)),
        },
    )
    active = [entry for entry in submissions if entry["attributes"].get("state") in ACTIVE_SUBMISSION_STATES]
    drafts = [entry for entry in submissions if entry["attributes"].get("state") == DRAFT_SUBMISSION_STATE]
    for entry in active:
        print(f"  審査の提出: {entry['id']} は {entry['attributes'].get('state')}")
    if args.submit and active:
        raise SystemExit(
            "審査中か、対応の要る提出があるので、新しく審査に出しません。App Store Connect の画面で状態を確認してください。"
        )

    # バージョンの必須の属性。null は未設定。応答に項目そのものが無いときは確かめられないので、注意だけ出す
    attributes = version["attributes"]
    missing = [key for key in VERSION_ATTRIBUTES if key in attributes and attributes[key] is None]
    unknown = [key for key in VERSION_ATTRIBUTES if key not in attributes]
    for key in VERSION_ATTRIBUTES:
        value = attributes.get(key)
        shown = "読めない" if key in unknown else "未設定" if value is None else str(value).lower()
        print(f"  {key}: {shown}")
    if unknown:
        print(f"  注意: {', '.join(unknown)} を App Store Connect から読めませんでした（画面で入っているか確かめてください）")
    if missing:
        message = (
            f"バージョン {version_string} の必須の項目が未設定です: {', '.join(missing)}。"
            "AppStore/app_info.json に書いて Metadata/App Store を流すか、App Store Connect の画面で入れてから流してください。"
        )
        if args.submit:
            raise SystemExit(message)
        print(f"  注意: {message}")

    # ビルドの選択
    build = find_build(client, app["id"], version_string, PLATFORM, args.build)
    current = client.get_or_none(f"/v1/appStoreVersions/{version['id']}/build")
    if current and current["id"] == build["id"]:
        print(f"  ビルド: 変更なし（{build_label(build)}）")
    else:
        print(f"  ビルド: {'付ける予定' if args.dry_run else '付ける'}")
        print(f"    build: {build_label(current)} → {build_label(build)}")
        write(
            "PATCH",
            f"/v1/appStoreVersions/{version['id']}/relationships/build",
            {"data": {"type": "builds", "id": build["id"]}},
        )

    release_type = version["attributes"].get("releaseType")
    print(f"  リリースの方法: {release_type}（{RELEASE_TYPES.get(release_type, '不明')}。変えるときは App Store Connect で）")

    if not args.submit:
        print("  審査への提出: しない（submit を true にしたときだけ出す）")
        print("完了")
        return 0

    draft = drafts[0] if drafts else None
    included = False
    if draft:
        items = client.get_all(f"/v1/reviewSubmissions/{draft['id']}/items", {"include": "appStoreVersion"})
        included = any(
            (((item.get("relationships") or {}).get("appStoreVersion") or {}).get("data") or {}).get("id") == version["id"]
            for item in items
        )
        print(f"  審査の提出: 下書き {draft['id']} を使う（バージョン {version_string} は{'入っている' if included else 'これから入れる'}）")
    else:
        print("  審査の提出: 下書きを作る")

    print(f"  審査への提出: {'出す予定' if args.dry_run else '出す'}（{version_string}・{build_label(build)}）")
    if args.dry_run:
        print("完了")
        return 0

    if draft is None:
        draft = write(
            "POST",
            "/v1/reviewSubmissions",
            {
                "data": {
                    "type": "reviewSubmissions",
                    "attributes": {"platform": PLATFORM},
                    "relationships": {"app": {"data": {"type": "apps", "id": app["id"]}}},
                }
            },
        )["data"]
    if not included:
        write(
            "POST",
            "/v1/reviewSubmissionItems",
            {
                "data": {
                    "type": "reviewSubmissionItems",
                    "relationships": {
                        "reviewSubmission": {"data": {"type": "reviewSubmissions", "id": draft["id"]}},
                        "appStoreVersion": {"data": {"type": "appStoreVersions", "id": version["id"]}},
                    },
                }
            },
        )
    submitted = write(
        "PATCH",
        f"/v1/reviewSubmissions/{draft['id']}",
        {"data": {"type": "reviewSubmissions", "id": draft["id"], "attributes": {"submitted": True}}},
    )
    state = ((submitted.get("data") or {}).get("attributes") or {}).get("state", "?")
    print(f"  審査に出しました（提出 {draft['id']}、状態 {state}）")
    print("完了")
    return 0


if __name__ == "__main__":
    sys.exit(main())
