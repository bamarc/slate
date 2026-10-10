import { useMemo } from "react";
import { cn } from "@/lib/utils";

export interface GanttTask {
  id: number | string;
  text: string;
  start: Date;
  end?: Date;
  duration?: number;
  progress?: number;
  parent?: number | string;
  type?: "task" | "summary" | "milestone";
}

export interface GanttLink {
  id: number | string;
  source: number | string;
  target: number | string;
  type: "e2s" | "s2s" | "e2e" | "s2e";
}

export interface GanttChartProps {
  tasks: GanttTask[];
  links?: GanttLink[];
  /** Width of one day column in pixels. */
  dayWidth?: number;
  /** Height of one task row in pixels. */
  rowHeight?: number;
  className?: string;
}

const MS_PER_DAY = 86_400_000;

function startOfDay(d: Date): Date {
  const out = new Date(d);
  out.setHours(0, 0, 0, 0);
  return out;
}

function daysBetween(a: Date, b: Date): number {
  return Math.round((startOfDay(b).getTime() - startOfDay(a).getTime()) / MS_PER_DAY);
}

function addDays(d: Date, days: number): Date {
  const out = new Date(d);
  out.setDate(out.getDate() + days);
  return out;
}

function taskEndDate(t: GanttTask): Date {
  if (t.end) return t.end;
  const dur = t.type === "milestone" ? 0 : Math.max(1, t.duration ?? 1);
  return addDays(t.start, dur);
}

const MONTH_NAMES = [
  "January", "February", "March", "April", "May", "June",
  "July", "August", "September", "October", "November", "December",
];

const HEADER_HEIGHT = 48;
const LABEL_COL_WIDTH = 200;

export function GanttChart({
  tasks,
  links = [],
  dayWidth = 32,
  rowHeight = 36,
  className,
}: GanttChartProps) {
  const { rangeStart, totalDays, monthGroups, today } = useMemo(() => {
    if (tasks.length === 0) {
      const now = startOfDay(new Date());
      return { rangeStart: now, totalDays: 30, monthGroups: [], today: now };
    }
    let min = tasks[0].start;
    let max = taskEndDate(tasks[0]);
    for (const t of tasks) {
      if (t.start < min) min = t.start;
      const e = taskEndDate(t);
      if (e > max) max = e;
    }
    const start = addDays(startOfDay(min), -2);
    const end = addDays(startOfDay(max), 2);
    const days = Math.max(1, daysBetween(start, end));

    const groups: { label: string; days: number; offset: number }[] = [];
    for (let i = 0; i < days; i++) {
      const d = addDays(start, i);
      const label = `${MONTH_NAMES[d.getMonth()]} ${d.getFullYear()}`;
      const last = groups[groups.length - 1];
      if (last?.label === label) {
        last.days += 1;
      } else {
        groups.push({ label, days: 1, offset: i });
      }
    }
    return {
      rangeStart: start,
      totalDays: days,
      monthGroups: groups,
      today: startOfDay(new Date()),
    };
  }, [tasks]);

  const gridWidth = totalDays * dayWidth;
  const bodyHeight = tasks.length * rowHeight;

  const taskIndex = useMemo(() => {
    const m = new Map<number | string, number>();
    tasks.forEach((t, i) => m.set(t.id, i));
    return m;
  }, [tasks]);

  const todayOffset = daysBetween(rangeStart, today);
  const todayVisible = todayOffset >= 0 && todayOffset <= totalDays;

  return (
    <div
      className={cn(
        "border rounded-md overflow-auto bg-card text-sm",
        className,
      )}
      style={{ maxHeight: 480 }}
      role="table"
      aria-label="Gantt chart"
    >
      <div
        className="relative"
        style={{ width: LABEL_COL_WIDTH + gridWidth, minWidth: "100%" }}
      >
        <div
          className="sticky top-0 z-20 flex bg-muted/80 backdrop-blur border-b"
          style={{ height: HEADER_HEIGHT }}
        >
          <div
            className="shrink-0 border-r flex items-end px-3 pb-1 font-medium text-muted-foreground"
            style={{ width: LABEL_COL_WIDTH }}
          >
            Task
          </div>
          <div className="relative" style={{ width: gridWidth }}>
            <div className="flex h-6 border-b">
              {monthGroups.map((g) => (
                <div
                  key={`${g.label}-${g.offset}`}
                  className="border-r px-2 text-xs font-medium text-muted-foreground truncate flex items-center"
                  style={{ width: g.days * dayWidth }}
                >
                  {g.label}
                </div>
              ))}
            </div>
            <div className="flex h-6">
              {Array.from({ length: totalDays }).map((_, i) => {
                const d = addDays(rangeStart, i);
                const isWeekend = d.getDay() === 0 || d.getDay() === 6;
                return (
                  <div
                    key={i}
                    className={cn(
                      "border-r text-[10px] text-center text-muted-foreground flex items-center justify-center",
                      isWeekend && "bg-muted",
                    )}
                    style={{ width: dayWidth }}
                  >
                    {d.getDate()}
                  </div>
                );
              })}
            </div>
          </div>
        </div>

        <div className="flex" style={{ height: bodyHeight }}>
          <div
            className="shrink-0 border-r"
            style={{ width: LABEL_COL_WIDTH }}
          >
            {tasks.map((t) => (
              <div
                key={t.id}
                className="px-3 border-b flex items-center truncate"
                style={{ height: rowHeight }}
                title={t.text}
              >
                <span className={cn(t.type === "summary" && "font-semibold")}>
                  {t.text}
                </span>
              </div>
            ))}
          </div>

          <div className="relative" style={{ width: gridWidth }}>
            {tasks.map((t) => (
              <div
                key={t.id}
                className="border-b flex"
                style={{ height: rowHeight }}
              >
                {Array.from({ length: totalDays }).map((_, i) => {
                  const d = addDays(rangeStart, i);
                  const isWeekend = d.getDay() === 0 || d.getDay() === 6;
                  return (
                    <div
                      key={i}
                      className={cn("border-r", isWeekend && "bg-muted/50")}
                      style={{ width: dayWidth }}
                    />
                  );
                })}
              </div>
            ))}

            {todayVisible && (
              <div
                className="absolute top-0 bottom-0 w-px bg-destructive/60 pointer-events-none z-10"
                style={{ left: todayOffset * dayWidth }}
                aria-label="Today"
              />
            )}

            {tasks.map((t, rowIdx) => {
              const startOffset = daysBetween(rangeStart, t.start);
              const top = rowIdx * rowHeight + 6;
              const barHeight = rowHeight - 12;
              if (t.type === "milestone") {
                const cx = startOffset * dayWidth;
                const cy = top + barHeight / 2;
                const size = barHeight / 2;
                return (
                  <svg
                    key={t.id}
                    className="absolute pointer-events-none"
                    style={{
                      left: cx - size,
                      top: cy - size,
                      width: size * 2,
                      height: size * 2,
                    }}
                  >
                    <polygon
                      points={`${size},0 ${size * 2},${size} ${size},${size * 2} 0,${size}`}
                      className="fill-amber-500 stroke-amber-700"
                    />
                  </svg>
                );
              }
              const end = taskEndDate(t);
              const days = Math.max(1, daysBetween(t.start, end));
              const left = startOffset * dayWidth;
              const width = days * dayWidth - 2;
              const progress = Math.min(100, Math.max(0, t.progress ?? 0));
              const isSummary = t.type === "summary";
              return (
                <div
                  key={t.id}
                  className={cn(
                    "absolute rounded shadow-sm overflow-hidden flex items-center px-2 text-xs text-primary-foreground",
                    isSummary ? "bg-slate-700" : "bg-primary",
                  )}
                  style={{ left, top, width, height: barHeight }}
                  title={`${t.text} · ${t.start.toLocaleDateString()} → ${end.toLocaleDateString()}${
                    t.progress != null ? ` · ${progress}%` : ""
                  }`}
                >
                  {progress > 0 && (
                    <div
                      className="absolute inset-y-0 left-0 bg-black/25"
                      style={{ width: `${progress}%` }}
                    />
                  )}
                  <span className="relative truncate">{t.text}</span>
                </div>
              );
            })}

            <svg
              className="absolute inset-0 pointer-events-none"
              width={gridWidth}
              height={bodyHeight}
            >
              <defs>
                <marker
                  id="gantt-arrow"
                  viewBox="0 0 10 10"
                  refX="8"
                  refY="5"
                  markerWidth="6"
                  markerHeight="6"
                  orient="auto-start-reverse"
                >
                  <path d="M0,0 L10,5 L0,10 z" className="fill-muted-foreground" />
                </marker>
              </defs>
              {links.map((link) => {
                const srcIdx = taskIndex.get(link.source);
                const tgtIdx = taskIndex.get(link.target);
                if (srcIdx == null || tgtIdx == null) return null;
                const src = tasks[srcIdx];
                const tgt = tasks[tgtIdx];
                const fromX = link.type.startsWith("e")
                  ? daysBetween(rangeStart, taskEndDate(src)) * dayWidth
                  : daysBetween(rangeStart, src.start) * dayWidth;
                const toX = link.type.endsWith("s")
                  ? daysBetween(rangeStart, tgt.start) * dayWidth
                  : daysBetween(rangeStart, taskEndDate(tgt)) * dayWidth;
                const fromY = srcIdx * rowHeight + rowHeight / 2;
                const toY = tgtIdx * rowHeight + rowHeight / 2;
                const midX = Math.max(fromX, toX) + 8;
                const d = `M${fromX},${fromY} L${midX},${fromY} L${midX},${toY} L${toX},${toY}`;
                return (
                  <path
                    key={link.id}
                    d={d}
                    className="stroke-muted-foreground"
                    strokeWidth={1.5}
                    fill="none"
                    markerEnd="url(#gantt-arrow)"
                  />
                );
              })}
            </svg>
          </div>
        </div>
      </div>
    </div>
  );
}
