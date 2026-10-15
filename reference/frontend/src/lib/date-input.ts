import { format, parse, isValid } from "date-fns";

export function parseGermanDateInput(input: string): Date | undefined {
  if (!input) return undefined;

  const normalized = input.replace(/[/-]/g, ".");

  const formats = ["dd.MM.yyyy", "d.M.yyyy", "dd.MM.yy", "d.M.yy"];

  for (const fmt of formats) {
    try {
      const parsed = parse(normalized, fmt, new Date());
      if (isValid(parsed)) {
        return parsed;
      }
    } catch {
      // continue
    }
  }

  return undefined;
}

export function formatGermanDateInput(date: Date | string | undefined): string {
  if (!date) return "";
  const d = typeof date === "string" ? new Date(date) : date;
  if (!isValid(d)) return "";
  return format(d, "dd.MM.yyyy");
}
