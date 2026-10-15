import {
  addDays,
  addYears,
  startOfWeek,
  endOfWeek,
  startOfMonth,
  endOfMonth,
  startOfYear,
  endOfYear,
  addMonths,
} from "date-fns";
import type { DateRange } from "react-day-picker";

export type QuickDatePresetKey =
  | "today"
  | "thisWeek"
  | "nextWeek"
  | "thisMonth"
  | "nextMonth"
  | "prevYear"
  | "thisYear"
  | "nextYear";

export interface QuickDatePresetDefinition {
  key: QuickDatePresetKey;
  label: string;
}

export const QUICK_DATE_PRESETS: QuickDatePresetDefinition[] = [
  { key: "today", label: "Heute" },
  { key: "thisWeek", label: "Diese Woche" },
  { key: "nextWeek", label: "Nächste Woche" },
  { key: "thisMonth", label: "Diesen Monat" },
  { key: "nextMonth", label: "Nächsten Monat" },
  { key: "prevYear", label: "Vorheriges Jahr" },
  { key: "thisYear", label: "Dieses Jahr" },
  { key: "nextYear", label: "Nächstes Jahr" },
];

export function resolvePresetRange(baseDate: Date, key: QuickDatePresetKey): DateRange {
  const options = { weekStartsOn: 1 as const };

  switch (key) {
    case "today":
      return { from: baseDate, to: baseDate };
    case "thisWeek":
      return {
        from: startOfWeek(baseDate, options),
        to: endOfWeek(baseDate, options),
      };
    case "nextWeek": {
      const nextWeek = addDays(baseDate, 7);
      return {
        from: startOfWeek(nextWeek, options),
        to: endOfWeek(nextWeek, options),
      };
    }
    case "thisMonth":
      return {
        from: startOfMonth(baseDate),
        to: endOfMonth(baseDate),
      };
    case "nextMonth": {
      const nextMonth = addMonths(baseDate, 1);
      return {
        from: startOfMonth(nextMonth),
        to: endOfMonth(nextMonth),
      };
    }
    case "prevYear": {
      const prevYear = addYears(baseDate, -1);
      return { from: startOfYear(prevYear), to: endOfYear(prevYear) };
    }
    case "thisYear":
      return {
        from: startOfYear(baseDate),
        to: endOfYear(baseDate),
      };
    case "nextYear": {
      const nextYear = addYears(baseDate, 1);
      return { from: startOfYear(nextYear), to: endOfYear(nextYear) };
    }
    default:
      return { from: baseDate, to: baseDate };
  }
}

export function resolvePresetSingleDate(baseDate: Date, key: QuickDatePresetKey): Date | undefined {
  const range = resolvePresetRange(baseDate, key);
  return range.from;
}
