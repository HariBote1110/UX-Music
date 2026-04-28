"""同期結果と参照タイムスタンプの比較メトリクス。"""

from __future__ import annotations

import os
import statistics
from typing import Any


def timing_alignment_metrics(
    predicted_lines: list[dict[str, Any]],
    reference_times_seconds: list[float],
    *,
    manual_tolerance_seconds: float | None = None,
) -> dict[str, Any]:
    """``manual_tolerance_seconds`` は手動調整 LRC のブレ（Bluetooth 遅延など）を差し引いた評価に使う。

    * 未指定時は環境変数 ``UX_MUSIC_SYNC_MANUAL_TOLERANCE_SECONDS``（既定 **0.5** 秒）。
    * ``timing_mae_after_tolerance_seconds`` … 各行 ``max(0, |err|-tol)`` の平均。
    * ``fraction_within_manual_tolerance`` … ``|err| <= tol`` の行の割合。
    """
    if len(predicted_lines) != len(reference_times_seconds):
        return {
            "valid": False,
            "reason": "length_mismatch",
            "predicted_count": len(predicted_lines),
            "reference_count": len(reference_times_seconds),
        }

    tol = manual_tolerance_seconds
    if tol is None:
        tol = float(os.environ.get("UX_MUSIC_SYNC_MANUAL_TOLERANCE_SECONDS", "0.5"))

    n = len(predicted_lines)
    abs_errors = [
        abs(float(predicted_lines[i].get("timestamp", -1)) - float(reference_times_seconds[i]))
        for i in range(n)
    ]

    residual = [max(0.0, e - tol) for e in abs_errors]

    matched_sources = sum(1 for row in predicted_lines if row.get("source") == "match")

    out: dict[str, Any] = {
        "valid": True,
        "line_count": n,
        "manual_tolerance_seconds": tol,
        "timing_mae_seconds": statistics.mean(abs_errors),
        "timing_median_abs_seconds": statistics.median(abs_errors),
        "timing_max_abs_seconds": max(abs_errors),
        "timing_mae_after_tolerance_seconds": statistics.mean(residual),
        "timing_median_residual_after_tolerance_seconds": statistics.median(residual),
        "fraction_within_manual_tolerance": sum(e <= tol + 1e-9 for e in abs_errors) / n,
        "fraction_within_1_0s": sum(e <= 1.0 for e in abs_errors) / n,
        "fraction_within_2_0s": sum(e <= 2.0 for e in abs_errors) / n,
        "source_match_fraction": matched_sources / n if n else 0.0,
    }
    return out


def per_line_timing_rows(
    predicted_lines: list[dict[str, Any]],
    reference_times_seconds: list[float],
    lyric_texts: list[str],
    *,
    manual_tolerance_seconds: float | None = None,
) -> list[dict[str, Any]]:
    """行ごとの予測時刻・参照時刻・符号付きずれ・残差（許容差し引き後）。"""
    tol = manual_tolerance_seconds
    if tol is None:
        tol = float(os.environ.get("UX_MUSIC_SYNC_MANUAL_TOLERANCE_SECONDS", "0.5"))

    rows: list[dict[str, Any]] = []
    for i in range(len(predicted_lines)):
        pred = float(predicted_lines[i].get("timestamp", -1))
        ref = float(reference_times_seconds[i])
        signed = pred - ref
        ad = abs(signed)
        txt = lyric_texts[i] if i < len(lyric_texts) else str(predicted_lines[i].get("text", ""))
        rows.append(
            {
                "index": i,
                "index_1based": i + 1,
                "text": txt,
                "pred_seconds": pred,
                "ref_seconds": ref,
                "signed_delta_seconds": signed,
                "abs_delta_seconds": ad,
                "residual_after_tolerance_seconds": max(0.0, ad - tol),
                "within_tolerance": ad <= tol + 1e-9,
                "source": str(predicted_lines[i].get("source", "") or ""),
            }
        )
    return rows


def format_per_line_report(
    per_line: list[dict[str, Any]],
    *,
    top_n: int = 15,
    manual_tolerance_seconds: float = 0.5,
) -> str:
    """人が読むテキスト表（ずれが大きい行を上に並べる）。"""
    sorted_rows = sorted(per_line, key=lambda r: -r["abs_delta_seconds"])
    show = sorted_rows[: max(1, top_n)]

    lines_out: list[str] = []
    lines_out.append(
        f"--- ずれ上位 {len(show)} 行（全 {len(per_line)} 行・手動許容 ±{manual_tolerance_seconds:.2f}s）---"
    )
    lines_out.append(
        f"{'#':>3} | {'|Δ|':>8} | {'符号付Δ':>9} | {'予測(s)':>9} | {'参照(s)':>9} | {'src':^10} | 歌詞（先頭）"
    )
    lines_out.append("-" * 88)
    for r in show:
        prev = r["text"].replace("\n", " ").strip()
        if len(prev) > 26:
            prev = prev[:23] + "..."
        lines_out.append(
            f"{r['index_1based']:>3} | {r['abs_delta_seconds']:>8.2f} | "
            f"{r['signed_delta_seconds']:>+9.2f} | "
            f"{r['pred_seconds']:>9.2f} | {r['ref_seconds']:>9.2f} | "
            f"{r['source']:^10} | {prev}"
        )

    # ヒント用サマリー
    tol = manual_tolerance_seconds
    late = sum(1 for r in per_line if r["signed_delta_seconds"] > tol + 1e-6)
    early = sum(1 for r in per_line if r["signed_delta_seconds"] < -(tol + 1e-6))
    big = sum(1 for r in per_line if r["abs_delta_seconds"] > 15.0)
    lines_out.append("")
    lines_out.append(
        f"概要: 予測が参照より遅い行(+Δ>{tol:g}s): {late} ／ 早い行(-Δ<-{tol:g}s): {early} ／ |Δ|>15s: {big}"
    )
    lines_out.append(
        "ヒント: +Δ が多いほど Whisper への対応セグメントが楽曲後ろ寄り／単調整列のドリフト。"
        " |Δ| が局所的にだけ大きい行は、その歌詞が繰り返しサビなど別セグメントへ誤結合している可能性。"
    )
    return "\n".join(lines_out)


def improvement_buckets(per_line: list[dict[str, Any]]) -> dict[str, int]:
    """絶対誤差の帯ごとの行数（どれか一つの帯にのみ計上）。"""
    out = {
        "abs_delta_ge_90s": 0,
        "abs_delta_30_to_90s": 0,
        "abs_delta_15_to_30s": 0,
        "abs_delta_5_to_15s": 0,
        "abs_delta_lt_5s": 0,
    }
    for r in per_line:
        ad = r["abs_delta_seconds"]
        if ad >= 90:
            out["abs_delta_ge_90s"] += 1
        elif ad >= 30:
            out["abs_delta_30_to_90s"] += 1
        elif ad >= 15:
            out["abs_delta_15_to_30s"] += 1
        elif ad >= 5:
            out["abs_delta_5_to_15s"] += 1
        else:
            out["abs_delta_lt_5s"] += 1
    return out
