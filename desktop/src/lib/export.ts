import type { SubtitleSegment } from "../types/hear";

/** 毫秒转 mm:ss（超过 1 小时显示 hh:mm:ss） */
export function formatTimestamp(ms: number): string {
  const totalSec = Math.max(0, Math.floor(ms / 1000));
  const h = Math.floor(totalSec / 3600);
  const m = Math.floor((totalSec % 3600) / 60);
  const s = totalSec % 60;
  const pad = (n: number) => String(n).padStart(2, "0");
  return h > 0 ? `${pad(h)}:${pad(m)}:${pad(s)}` : `${pad(m)}:${pad(s)}`;
}

/** 毫秒转 SRT 时间戳 00:01:23,450 */
export function formatSrtTime(ms: number): string {
  const clamped = Math.max(0, Math.floor(ms));
  const h = Math.floor(clamped / 3_600_000);
  const m = Math.floor((clamped % 3_600_000) / 60_000);
  const s = Math.floor((clamped % 60_000) / 1000);
  const milli = clamped % 1000;
  const pad = (n: number, len = 2) => String(n).padStart(len, "0");
  return `${pad(h)}:${pad(m)}:${pad(s)},${pad(milli, 3)}`;
}

/** 毫秒转 WebVTT 时间戳 00:01:23.450 */
export function formatVttTime(ms: number): string {
  return formatSrtTime(ms).replace(",", ".");
}

/** 二分查找当前播放时间对应的活跃字幕段落索引 */
export function findActiveSegmentIndex(
  segments: SubtitleSegment[],
  positionMs: number
): number {
  if (segments.length === 0) return -1;
  let lo = 0;
  let hi = segments.length - 1;
  let candidate = -1;
  while (lo <= hi) {
    const mid = (lo + hi) >> 1;
    const seg = segments[mid];
    if (positionMs >= seg.startMs && positionMs <= seg.endMs) {
      return mid;
    }
    if (seg.startMs <= positionMs) {
      candidate = mid;
      lo = mid + 1;
    } else {
      hi = mid - 1;
    }
  }
  // 处于两句间隙时，如果距离上一句结束不足 1.2s，维持上一句高亮，避免频繁闪烁
  if (candidate >= 0 && positionMs - segments[candidate].endMs <= 1200) {
    return candidate;
  }
  return -1;
}

/** 将 [mm:ss] 或 [hh:mm:ss] 解析为毫秒，供一键总结时间戳点击跳转 */
export function parseSummaryTimestampMs(label: string): number | null {
  const parts = label.split(":").map((p) => Number(p));
  if (parts.some((n) => Number.isNaN(n) || n < 0)) return null;
  if (parts.length === 2) {
    return (parts[0] * 60 + parts[1]) * 1000;
  }
  if (parts.length === 3) {
    return (parts[0] * 3600 + parts[1] * 60 + parts[2]) * 1000;
  }
  return null;
}

/** 导出双语或仅译文 SRT */
export function buildSrt(
  segments: SubtitleSegment[],
  bilingual = true
): string {
  return segments
    .map((seg, idx) => {
      const start = formatSrtTime(seg.startMs);
      const end = formatSrtTime(Math.max(seg.endMs, seg.startMs + 500));
      const speaker = seg.speakerLabel ? `[${seg.speakerLabel}] ` : "";
      const body = bilingual
        ? `${speaker}${seg.translatedText}\n${seg.sourceText}`
        : `${speaker}${seg.translatedText}`;
      return `${idx + 1}\n${start} --> ${end}\n${body}\n`;
    })
    .join("\n");
}

/** 导出 Markdown 完整带时间戳双语记录 */
export function buildMarkdown(
  segments: SubtitleSegment[],
  summaryMarkdown?: string
): string {
  const lines: string[] = ["# 听见（Hear）录音转写与翻译记录", ""];
  if (summaryMarkdown && summaryMarkdown.trim()) {
    lines.push("## 一键总结", "", summaryMarkdown.trim(), "", "---", "");
  }
  lines.push("## 时间轴全文", "");
  for (const seg of segments) {
    const ts = formatTimestamp(seg.startMs);
    const who =
      seg.speakerLabel ?? (seg.channel === "mic" ? "我" : "对方");
    lines.push(`- **[${ts}] ${who}**`);
    lines.push(`  - 原文：${seg.sourceText}`);
    lines.push(`  - 译文：${seg.translatedText}`);
  }
  return lines.join("\n") + "\n";
}
